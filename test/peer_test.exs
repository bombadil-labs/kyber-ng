defmodule Kyber.PeerTest do
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, DurableStore, Federation, Harness, Keys, Peer}

  @human_seed String.duplicate("cd", 32)

  # the T5 federation_test lifecycle pattern: peer tests inspect the WHOLE
  # store, so every test's setup reboots :kyber on a fresh tmp log_path;
  # setup_all only captures the baseline env and restores it on exit — the
  # real ~/.kyber is never touched (config/test.exs points log_path/keyring_dir
  # under tmp).
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
      "kyber-peer-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
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
    assert {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    on_exit(fn ->
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, agent_seed: agent_seed, log_path: log_path}
  end

  defp source_event(suffix, n) do
    %{
      "message_id" => "message:discord:#{suffix}:#{n}",
      "channel_id" => "channel:discord:#{suffix}",
      "session_id" => "session:discord:#{suffix}",
      "content" => "hello from #{suffix}:#{n}"
    }
  end

  # a peer bound to an ephemeral port; the socket is closed on test exit.
  defp start_peer do
    assert {:ok, pid} = Peer.start_link(port: 0)
    on_exit(fn -> if Process.alive?(pid), do: Peer.stop(pid) end)
    {pid, Peer.port(pid)}
  end

  # ------------------------------------------------------------------ AC2

  test "AC2: a live exchange round-trips an exported claim into a FRESH store; re-send dedups",
       %{keyring_dir: keyring_dir} do
    # store A (booted in setup): ingest a fixture claim, export, capture the wire
    assert {:ok, human_id} =
             Harness.ingest(source_event("11111111111111111111", 1), keyring_dir)

    assert {:ok, wire_text} = Federation.export()
    refute String.ends_with?(wire_text, "\n")

    # store B: a FRESH log — the export's own store is NOT the peer's store
    log_dir_b = fresh_dir(System.tmp_dir!(), "store-b")
    boot_on(Path.join(log_dir_b, "store.jsonl"))

    {_pid, port} = start_peer()

    assert {:ok, "ok imported=1 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, wire_text)

    # the door re-verified it: the claim is now in store B
    assert DeltaSet.member?(DurableStore.set(), human_id)

    # re-send the SAME frame: dedup across the network
    assert {:ok, "ok imported=0 skipped=1 refused=0"} =
             Peer.send_wire("localhost", port, wire_text)

    File.rm_rf(log_dir_b)
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: a frame of garbage lines is refused per line, never a crash" do
    {_pid, port} = start_peer()

    garbage = "not json {\nalso not json ["

    assert {:ok, "ok imported=0 skipped=0 refused=2"} =
             Peer.send_wire("localhost", port, garbage)
  end

  test "AC3: an empty frame reports zeros — no phantom skipped" do
    {_pid, port} = start_peer()

    assert {:ok, "ok imported=0 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, "")
  end

  test "AC3: a frame over the size cap is refused with a clean status (P5 bound)" do
    {_pid, port} = start_peer()

    # stream 2 MiB of non-blank junk with NO terminator — the handler must
    # refuse at the cap (:too_large) instead of accumulating without bound
    assert {:ok, sock} =
             :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])

    chunk = String.duplicate("x", 4096) <> "\n"

    # push past the cap; the handler's refusal close can land mid-stream —
    # a failed send then is the refusal arriving, not the assertion target
    Enum.reduce_while(1..512, :ok, fn _, _acc ->
      case :gen_tcp.send(sock, chunk) do
        :ok -> {:cont, :ok}
        {:error, _closed} = done -> {:halt, done}
      end
    end)

    assert {:ok, "err frame_too_large\n"} = :gen_tcp.recv(sock, 0, 15_000)
    assert :ok = :gen_tcp.close(sock)

    # the listener survives the refusal — the next connection is served
    assert {:ok, "ok imported=0 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, "")
  end

  test "AC3: concurrent connections beyond the handler cap are refused, then re-opened (P5 bound)" do
    {_pid, port} = start_peer()

    # hold exactly @max_handlers connections open (idle — each parks a handler)
    held =
      for _ <- 1..16 do
        {:ok, sock} =
          :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])

        sock
      end

    # the cap is full: the next connection is REFUSED (accept -> close) —
    # send_wire sees the close, and the listener stays alive
    assert {:error, :closed} = Peer.send_wire("localhost", port, "")

    # release the held sockets; the handler count drains via the monitors
    for sock <- held, do: :ok = :gen_tcp.close(sock)

    # the drain is async (handler exit -> DOWN -> decrement), so poll with a
    # bounded no-sleep retry — each attempt is a real connect round-trip
    # (the pinned explicit-state-polling idiom; never the sleep primitive)
    deadline = System.monotonic_time(:millisecond) + 10_000

    result =
      Enum.reduce_while(1..100, {:error, :closed}, fn _, _ ->
        case Peer.send_wire("localhost", port, "") do
          {:ok, status} ->
            {:halt, {:ok, status}}

          {:error, :closed} ->
            if System.monotonic_time(:millisecond) > deadline do
              {:halt, {:error, :closed}}
            else
              {:cont, {:error, :closed}}
            end
        end
      end)

    assert result == {:ok, "ok imported=0 skipped=0 refused=0"}
  end

  test "AC3: a TWO-CLAIM frame imports both — no phantom blank segment (rev 3 strip-then-join)",
       %{keyring_dir: keyring_dir} do
    # store A: two fixture claims -> a two-envelope export (no trailing newline)
    assert {:ok, _} = Harness.ingest(source_event("22222222222222222222", 1), keyring_dir)
    assert {:ok, _} = Harness.ingest(source_event("22222222222222222222", 2), keyring_dir)
    assert {:ok, two_claim_text} = Federation.export()
    assert length(String.split(String.trim_trailing(two_claim_text, "\n"), "\n")) == 2

    # store B: a fresh log; a two-envelope frame must import BOTH — the strip-
    # then-join reconstruction forbids a blank segment between claims (which
    # import would count as a phantom skipped=1)
    log_dir_b = fresh_dir(System.tmp_dir!(), "store-b")
    boot_on(Path.join(log_dir_b, "store.jsonl"))

    {_pid, port} = start_peer()

    assert {:ok, "ok imported=2 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, two_claim_text)

    File.rm_rf(log_dir_b)
  end

  test "AC3: a client that drops mid-frame is a non-event — the listener serves the next" do
    {_pid, port} = start_peer()

    # connect, send a partial frame with NO terminator, then drop
    assert {:ok, sock} =
             :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])

    assert :ok = :gen_tcp.send(sock, "{partial, no terminator}\n")
    assert :ok = :gen_tcp.close(sock)

    # the listener is unharmed — the next connection is served
    assert {:ok, "ok imported=0 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, "")
  end

  test "AC3: a silent client is dropped after the handler recv timeout" do
    {_pid, port} = start_peer()

    assert {:ok, sock} =
             :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])

    # send nothing: the handler recv times out, closes the socket -> :closed
    # here (blocking recv on the socket is the poll, never a sleep primitive)
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 15_000)

    # and the listener is still alive
    assert {:ok, "ok imported=0 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, "")
  end

  test "AC3: a connection to a closed port -> {:error, reason} from send_wire" do
    assert {:ok, pid} = Peer.start_link(port: 0)
    port = Peer.port(pid)
    assert :ok = Peer.stop(pid)

    assert {:error, _reason} = Peer.send_wire("localhost", port, "")
  end

  test "AC3: Peer.stop -> start/stop/start on the SAME port works" do
    assert {:ok, p1} = Peer.start_link(port: 0)
    port = Peer.port(p1)
    assert :ok = Peer.stop(p1)

    assert {:ok, p2} = Peer.start_link(port: port)
    assert Peer.port(p2) == port

    assert {:ok, "ok imported=0 skipped=0 refused=0"} =
             Peer.send_wire("localhost", port, "")

    assert :ok = Peer.stop(p2)
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: store-down is a clean refusal line, never a crash", %{log_path: log_path} do
    {_pid, port} = start_peer()

    stop_app()

    assert {:ok, "err store_not_running"} =
             Peer.send_wire("localhost", port, "anything at all")

    # re-boot before returning: no later test may see a stopped store
    boot_on(log_path)
    assert is_list(Harness.view())
  end
end
