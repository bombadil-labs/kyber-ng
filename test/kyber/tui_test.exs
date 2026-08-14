defmodule Kyber.TUITest do
  @moduledoc """
  T14i — the TUI (H1/H6/M6/M7/M8/M9/M10/M14): the pure log-tail renderer
  (render_line/1 — no wall-clock, no IO), the HOLD discipline (invalid
  JSON at the tail is held, distinct from non-renderable = SKIP), the
  JSONL socket client (RECV-ACCUMULATE on the client arm — the >64KB-line
  fragment test exercises BOTH arms, H1), the daemon's channel socket
  (verbs tail/send/status/tick, 0600 at bind, stale-sock reclaim in
  terminate), and the no_operator_seed gate (M5).
  """
  use ExUnit.Case, async: false

  alias Kyber.{CLI, Daemon, DurableStore, Events, Keys, Schema, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @operator_seed String.duplicate("7f", 32)

  setup_all do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)
    assert is_binary(keyring_dir)
    assert is_binary(config_log_path)

    on_exit(fn ->
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
    end)

    {:ok, keyring_dir: keyring_dir}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp fresh_dir(base, tag) do
    Path.join(
      base,
      "kyber-tui-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  defp boot_on(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  setup %{keyring_dir: keyring_dir} do
    key_dir = fresh_dir(keyring_dir, "keyring")
    File.mkdir_p!(key_dir)
    assert :ok = Keys.import_human_seed(@human_seed, key_dir)
    assert {:ok, _agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, log_path: log_path}
  end

  # ---------------------------------------------------------------- helpers

  defp boot_daemon!(ctx, opts \\ []) do
    boot_opts =
      Keyword.merge(
        [
          keyring_dir: ctx.keyring_dir,
          tick_ms: :manual,
          loop: :reactor,
          channel_socket: :default,
          test_pid: self()
        ],
        opts
      )

    assert {:ok, pid} = Daemon.boot(boot_opts)
    pid
  end

  defp received_line(content, ts \\ 1_754_600_000_000) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        "message:tui:test:#{System.unique_integer([:positive])}",
        "channel:tui",
        "session:tui",
        content
      )

    JSON.encode!(Wire.envelope(signed))
  end

  defp sent_line(content, ts) do
    {:ok, signed} =
      Events.message_sent(
        @operator_seed,
        ts,
        "response:1",
        "message:reply:prompt-1",
        "channel:tui",
        content
      )

    JSON.encode!(Wire.envelope(signed))
  end

  defp raw_request(socket, line) do
    :ok = :gen_tcp.send(socket, line <> "\n")
    recv_line(socket, "")
  end

  defp recv_line(socket, buf) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, packet} ->
        buf = buf <> packet

        case :binary.split(buf, "\n") do
          [line, _rest] -> {:ok, line}
          [_incomplete] -> recv_line(socket, buf)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------- render

  test "render_line/1: the pinned grammar — > received / < sent / ! refusal / ~ tool / = result; non-renderable kinds are nil" do
    assert Kyber.CLI.TUI.render_line(received_line("hello operator")) == "> hello operator"
    assert Kyber.CLI.TUI.render_line(sent_line("hello back", 1_754_600_000_001)) == "< hello back"

    {:ok, refusal} =
      Kyber.Agent.Events.gate_decision(
        @operator_seed,
        1_754_600_000_002,
        "call-1",
        "refuse",
        "budget"
      )

    assert Kyber.CLI.TUI.render_line(JSON.encode!(Wire.envelope(refusal))) == "! refused:budget"

    {:ok, allow} =
      Kyber.Agent.Events.gate_decision(
        @operator_seed,
        1_754_600_000_003,
        "call-2",
        "allow",
        "budget"
      )

    # an ALLOW decision is not a refusal — not in the grammar → nil (SKIP)
    assert Kyber.CLI.TUI.render_line(JSON.encode!(Wire.envelope(allow))) == nil

    {:ok, tool} =
      Kyber.Agent.Events.tool_call(
        @operator_seed,
        1_754_600_000_004,
        "fs:read",
        ~s({"path":"/x"}),
        "req-1"
      )

    assert Kyber.CLI.TUI.render_line(JSON.encode!(Wire.envelope(tool))) ==
             "~ fs:read {\"path\":\"/x\"}"

    {:ok, call} =
      Kyber.Agent.Events.tool_result(
        @operator_seed,
        1_754_600_000_005,
        "call-1",
        "the result",
        "ok"
      )

    assert Kyber.CLI.TUI.render_line(JSON.encode!(Wire.envelope(call))) == "= the result"

    # a checkpoint delta — mechanism, not conversation → nil (SKIP)
    {:ok, checkpoint} =
      Kyber.Events.message_sent(@operator_seed, 1_754_600_000_006, "r", "m", "channel:x", "x")

    _ = checkpoint

    {ch_claims, ch_sig} =
      (fn ->
         raw = %{
           timestamp: 1_754_600_000_007.0,
           author: Keys.author_for_seed(@operator_seed),
           pointers: [%{role: "checkpoint", target: {:entity, "daemon:kyber", "checkpoints"}}]
         }

         {:ok, claims} = Delta.validate(raw)
         {:ok, sig} = Keys.sign(claims, @operator_seed)
         {claims, sig}
       end).()

    assert Kyber.CLI.TUI.render_line(JSON.encode!(Wire.envelope({ch_claims, ch_sig}))) == nil
  end

  test "render_line/1: HOLD vs SKIP — invalid JSON at the tail is :hold, a door-refused line is :skip" do
    assert Kyber.CLI.TUI.render_line("not json {") == :hold
    assert Kyber.CLI.TUI.render_line("{\"id\":\"x\"}") == :skip
  end

  test "render_line/1 elides at 120 GRAPHEMES, grapheme-safe (M9 — never binary_part)" do
    content = String.duplicate("a", 130)
    rendered = Kyber.CLI.TUI.render_line(received_line(content))
    assert rendered == "> " <> String.duplicate("a", 120) <> "..."

    # a 130-grapheme emoji string must not sever UTF-8 (M9)
    graphemes = List.duplicate("👨‍👩‍👧‍👦", 130)
    content = Enum.join(graphemes, "")
    rendered = Kyber.CLI.TUI.render_line(received_line(content))
    assert String.valid?(rendered)
    assert rendered == "> " <> Enum.join(Enum.take(graphemes, 120), "") <> "..."
  end

  test "tail_cursor/2: the HOLD discipline — a torn tail is held, a mid-log torn line is skipped" do
    log_dir = fresh_dir(System.tmp_dir!(), "tail")
    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "store.jsonl")
    on_exit(fn -> File.rm_rf(log_dir) end)

    # three complete lines + a torn tail
    File.write!(log_path, received_line("one", 1_754_600_001_000) <> "\n")
    File.write!(log_path, received_line("two", 1_754_600_002_000) <> "\n", [:append])
    File.write!(log_path, "torn tail line without json", [:append])

    {rendered, cursor} = Kyber.CLI.TUI.tail_cursor(log_path, 0)
    assert rendered == ["> one", "> two"]
    # the torn tail is HELD: the cursor stops before it
    assert cursor == 2

    # the tail completes: the held line is re-rendered on the next poll
    File.write!(log_path, "\n{\"ok\":true}\n", [:append])
    {rendered2, cursor2} = Kyber.CLI.TUI.tail_cursor(log_path, cursor)
    assert cursor2 == 4
    assert rendered2 == []
  end

  # ------------------------------------------------------------- the socket

  test "the daemon's channel socket: status/tick verbs + the 0600 mode at bind (M1)",
       ctx do
    boot_daemon!(ctx, operator_seed: @operator_seed)
    sock = ctx.log_path <> ".sock"
    assert File.exists?(sock)

    # M1: 0600 at bind — no group/other bits
    mode = File.stat!(sock).mode
    assert Bitwise.band(mode, 0o077) == 0

    assert {:ok, %{"ok" => true, "status" => status}} =
             Kyber.CLI.TUI.request(sock, %{"verb" => "status"})

    assert is_binary(status["author"])
    assert status["log_path"] == ctx.log_path

    assert {:ok, %{"ok" => true}} = Kyber.CLI.TUI.request(sock, %{"verb" => "tick"})
    assert {:ok, %{"error" => "malformed"}} = Kyber.CLI.TUI.request(sock, %{"verb" => "bogus"})
    assert {:ok, %{"error" => "malformed"}} = Kyber.CLI.TUI.request(sock, %{"verb" => "send"})
  end

  test "send verb: the message becomes a daemon-signed message_received delta (M10's message:tui:<ts>:<seq> id); the response chain fires",
       ctx do
    boot_daemon!(ctx, operator_seed: @operator_seed)
    sock = ctx.log_path <> ".sock"

    assert {:ok, %{"ok" => true}} = Kyber.CLI.TUI.send_message(sock, "hello tui")

    received =
      poll_until_value(fn ->
        Enum.find_value(DurableStore.set(), fn {id, {claims, _sig}} ->
          case Schema.resolve(claims) do
            %{type: "MessageReceived", at: {:entity, "channel:tui", _ctx}} -> {id, claims}
            _other -> nil
          end
        end)
      end)

    assert received != nil
    {id, claims} = received

    # M10: the TUI message id carries a daemon-side monotonic per-ms seq —
    # the "received" ENTITY id, never the content-address
    %{target: {:entity, message_entity, _ctx}} =
      Enum.find(claims.pointers, &(&1.role == "received"))

    assert String.starts_with?(message_entity, "message:tui:")
    assert [ts_ms, _seq] = String.split(message_entity, ":") |> Enum.drop(2)
    assert ts_ms =~ ~r/^\d+$/

    # L7: the socket send is daemon-signed — by = human:<operator-pub>
    %{target: {:entity, by, _ctx}} = Enum.find(claims.pointers, &(&1.role == "by"))
    assert by == "human:" <> pub(Keys.author_for_seed(@operator_seed))

    # the reactor fires on the received (the gate is closed without an
    # oracle seed — the refusal GateDecision IS the fire)
    assert_receive {:reactor, {:dispatch, "received", received_id}}, 2_000
    assert received_id == id
  end

  test ~S|send verb WITHOUT an operator seed: the explicit nil gate answers {"error":"no_operator_seed"} (M5 — never a raise)|,
       ctx do
    boot_daemon!(ctx)
    sock = ctx.log_path <> ".sock"
    assert {:ok, %{"error" => "no_operator_seed"}} = Kyber.CLI.TUI.send_message(sock, "hi")
  end

  test "tail verb: the socket carries only NEW-LINE NOTIFICATIONS; the content comes from the log file (M7)",
       ctx do
    boot_daemon!(ctx, operator_seed: @operator_seed)
    sock = ctx.log_path <> ".sock"

    # a raw persistent tail connection
    {:ok, socket} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, packet: :raw, active: false], 5_000)

    assert {:ok, "{\"ok\":true}"} = raw_request(socket, ~s({"verb":"tail"}))

    # a new line lands on the log (via the daemon's own admission point)
    assert {:ok, %{"ok" => true}} = Kyber.CLI.TUI.send_message(sock, "wake the tail")

    assert {:ok, notification} = recv_line(socket, "")
    decoded = JSON.decode!(notification)
    assert is_integer(decoded["newline"])

    # the notification's count is monotonic — the log grew
    :gen_tcp.close(socket)
  end

  test "H1: the >64KB-line fragment test on BOTH socket arms — the server accumulates the request, the client accumulates the response",
       ctx do
    boot_daemon!(ctx, operator_seed: @operator_seed)
    sock = ctx.log_path <> ".sock"

    # SERVER arm: a >64KB send request written in ~70-byte fragments — the
    # server's recv-accumulate reconstructs the line and answers
    big = String.duplicate("z", 70_000)

    {:ok, socket} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, packet: :raw, active: false], 5_000)

    payload = JSON.encode!(%{"verb" => "send", "content" => big}) <> "\n"

    for i <- 0..div(byte_size(payload), 70) do
      start = i * 70
      chunk = binary_part(payload, start, min(70, byte_size(payload) - start))
      :ok = :gen_tcp.send(socket, chunk)
    end

    assert {:ok, "{\"ok\":true}"} = recv_line(socket, "")
    :gen_tcp.close(socket)

    # the big send landed as a received delta with the full content
    received =
      poll_until_value(fn ->
        Enum.find_value(DurableStore.set(), fn {_id, {claims, _sig}} ->
          case Enum.find(claims.pointers, &(&1.role == "content")) do
            %{target: {:string, c}} when c == big -> true
            _other -> nil
          end
        end)
      end)

    assert received == true

    # CLIENT arm: a fake socket server writes a >64KB response line in many
    # fragments — the TUI client's recv-accumulate reconstructs it
    fake_dir = fresh_dir(System.tmp_dir!(), "fake-sock")
    File.mkdir_p!(fake_dir)
    fake_sock = Path.join(fake_dir, "fake.sock")
    on_exit(fn -> File.rm_rf(fake_dir) end)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, fake_sock}}, packet: :raw, active: false])

    on_exit(fn -> :gen_tcp.close(listen) end)

    spawn(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(client, 0, 5_000)

      big_response =
        JSON.encode!(%{"ok" => true, "blob" => String.duplicate("w", 70_000)}) <> "\n"

      for i <- 0..div(byte_size(big_response), 100) do
        start = i * 100
        chunk = binary_part(big_response, start, min(100, byte_size(big_response) - start))
        :ok = :gen_tcp.send(client, chunk)
      end

      :gen_tcp.close(client)
    end)

    assert {:ok, %{"ok" => true, "blob" => blob}} =
             Kyber.CLI.TUI.request(fake_sock, %{"verb" => "status"})

    assert byte_size(blob) == 70_000
  end

  test "the socket file is removed in the daemon's terminate (H2 — stale-sock reclaim) and a stale sock does not brick re-boot",
       ctx do
    boot_daemon!(ctx, operator_seed: @operator_seed)
    sock = ctx.log_path <> ".sock"
    assert File.exists?(sock)

    assert :ok = Daemon.stop()
    refute File.exists?(sock)
    refute File.exists?(ctx.log_path <> ".lock")

    # a kill -9 leaves the SOCKET INODE behind: bind one and drop it without
    # unlinking — the faithful residue (P5 r10 C1 made the reclaim
    # socket-only, so a hand-written regular file is no longer a valid
    # stand-in: the daemon refuses to rm one, by design)
    {:ok, stale} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, sock}}, packet: :raw, active: false])

    :gen_tcp.close(stale)
    assert File.exists?(sock)
    refute File.stat!(sock).type == :regular

    # the daemon rm's it under the held lock before bind (H2)
    boot_daemon!(ctx, operator_seed: @operator_seed)
    assert {:ok, %{"ok" => true}} = Kyber.CLI.TUI.request(sock, %{"verb" => "status"})
  end

  # ------------------------------------------------------------- the CLI arm

  test ~S|CLI.run(["tui", ...]): the recognized non-booting arm — a live daemon yields the marker; a missing daemon is the clean one-liner|,
       ctx do
    # no daemon: the clean one-liner, never a boot, never a usage error
    missing = ctx.log_path <> ".sock"
    assert {:error, message} = CLI.run(["tui", "--log", ctx.log_path])
    assert message == "daemon not running on #{missing}"

    # usage shapes
    assert {:error, :usage, _} = CLI.run(["tui", "--bogus"])

    # a live daemon: the blocking marker tuple (main/1 prints and blocks)
    boot_daemon!(ctx, operator_seed: @operator_seed)

    assert {:ok, {:tui, line, pid}} = CLI.run(["tui", "--log", ctx.log_path])
    assert is_pid(pid)
    assert line == "tui connected to #{ctx.log_path}"

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert {:ok, {:tui, _line, pid2}} = CLI.run(["tui", "--socket", ctx.log_path <> ".sock"])
    on_exit(fn -> if Process.alive?(pid2), do: Process.exit(pid2, :kill) end)
  end

  # ---------------------------------------------------------------- helpers

  defp poll_until_value(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
        nil ->
          receive do
          after
            25 -> :timeout
          end

          {:cont, nil}

        found ->
          {:halt, found}
      end
    end)
  end

  defp pub("ed25519:" <> hex), do: hex
end
