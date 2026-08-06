defmodule Kyber.DaemonSmokeTest do
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, Keys}

  @human_seed String.duplicate("cd", 32)

  # The operational gate (AC7) as a repo artifact: this BUILDS the real escript
  # and drives it as separate OS processes — a long-running `kyber daemon`
  # (spawned via Port so it can block) plus `kyber ingest`/`view`/`render` VMs
  # that talk to it ONLY through the shared --log file. It proves the loop
  # closes for real: boot -> ingest -> the handler fires -> the ack persists ->
  # the vault renders it -> a second daemon is refused -> SIGTERM is clean ->
  # re-boot never re-fires. AC5/AC6 (the pulse bus + admission knob) are driven
  # in-VM by daemon_test.exs, because a pulse is pushed through
  # `Kyber.Gather.notify/1` — an OTP-level bus with no CLI surface by design
  # (a pulse is ephemeral; D5). The build is ~30-60s, so it runs only under
  # KYBER_SMOKE=1; otherwise it passes as a no-op. It NEVER touches ~/.kyber,
  # and the daemon kill is registered at spawn time so no process leaks.
  @tag :smoke
  test "daemon smoke: boot/refuse/SIGTERM (AC1), ingest->ack->vault (AC4/AC7), re-boot no re-fire (AC3)",
       %{} do
    if System.get_env("KYBER_SMOKE") != "1" do
      IO.puts("skipped: set KYBER_SMOKE=1 to run the daemon escript smoke")
    else
      root = File.cwd!()
      binary = Path.join(root, "kyber")
      on_exit(fn -> File.rm(binary) end)

      {build_out, build_code} =
        System.cmd("mix", ["escript.build"], cd: root, stderr_to_stdout: true)

      assert build_code == 0, "escript.build failed: #{build_out}"

      # the real store is never touched
      real_store = Path.join(System.user_home!(), ".kyber/store.jsonl")
      real_before = if File.exists?(real_store), do: File.read!(real_store), else: :absent

      work = fresh("smoke")
      File.mkdir_p!(work)
      on_exit(fn -> File.rm_rf(work) end)

      log = Path.join(work, "store.jsonl")
      keyring = Path.join(work, "keyring")
      File.mkdir_p!(keyring)
      :ok = Keys.import_human_seed(@human_seed, keyring)
      {:ok, _agent} = Keys.mint_agent_seed(keyring)
      agent8 = author8(load_agent(keyring))

      source = Path.join(work, "source.json")

      File.write!(
        source,
        JSON.encode!(%{
          "message_id" => "message:smoke:1",
          "channel_id" => "channel:smoke",
          "session_id" => "session:smoke",
          "content" => "hello daemon"
        })
      )

      # 1. boot the daemon (Port: it blocks; a tmp cwd so a crash dump never
      #    lands in the repo). Register the kill AT spawn time — failure-atomic.
      port = boot_daemon(binary, log, keyring, work)
      register_kill(port)

      assert_receive {^port, {:data, {:eol, "kyber daemon on " <> _}}}, 60_000
      assert File.exists?(Daemon.lock_path(log)), "the daemon must hold its lock"

      # AC1: a second daemon on the same log is refused with the one-liner, exit 1
      {refuse_out, refuse_code} =
        System.cmd(binary, ["daemon", "--log", log, "--keyring", keyring], stderr_to_stdout: true)

      assert refuse_code == 1, "a second daemon must exit 1: #{refuse_out}"
      assert refuse_out =~ "daemon already running on #{log}"

      # AC4/AC7: ingest a message.received via the CLI (a SEPARATE VM on the
      #          same --log); the daemon observes it through the file
      {ingest_out, ingest_code} =
        System.cmd(binary, ["--log", log, "ingest", source, "--keyring", keyring],
          stderr_to_stdout: true
        )

      assert ingest_code == 0, "ingest failed: #{ingest_out}"
      received_id = String.trim(ingest_out)

      # watch the ack persist (bounded explicit polling — never Process.sleep)
      assert {:ok, view} = poll_until(fn -> view(binary, log) end, &(sent_lines(&1) != []), 100)

      # exactly one message.sent, signed by the AGENT key, plus the received
      assert [sent_line] = sent_lines(view)
      assert sent_line =~ " sent #{agent8} "
      assert view =~ "#{received_id} received "

      # AC7: the vault renders the conversation, and the ack body is verbatim
      vault = Path.join(work, "vault")
      {render_out, render_code} = System.cmd(binary, ["--log", log, "render", vault])
      assert render_code == 0, "render failed: #{render_out}"

      ack_file = Path.join([vault, "claims", "claim_#{received_id}.md"])
      assert File.exists?(ack_file), "the received claim must render in the vault"

      assert vault_bodies(vault) |> Enum.any?(&String.contains?(&1, "ack #{received_id}")),
             "the vault must render the ack reply verbatim"

      # AC1: SIGTERM -> clean shutdown, exit 0, the lock releases
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      System.cmd("kill", [Integer.to_string(os_pid)])
      assert_receive {^port, {:exit_status, 0}}, 30_000
      refute File.exists?(Daemon.lock_path(log)), "SIGTERM must release the lock"

      # AC3: re-boot on the SAME store — the cursor is re-derived from the
      #      persisted checkpoint, so the daemon does NOT re-fire
      sent_before = sent_lines(view(binary, log))
      assert length(sent_before) == 1

      port2 = boot_daemon(binary, log, keyring, work)
      register_kill(port2)
      assert_receive {^port2, {:data, {:eol, "kyber daemon on " <> _}}}, 60_000

      # let many ticks pass; the sent count must stay exactly 1 the whole time
      for _ <- 1..20 do
        assert length(sent_lines(view(binary, log))) == 1, "the daemon re-fired after re-boot"
        yield(50)
      end

      # kill the re-boot daemon (Port.close does NOT terminate the child)
      {:os_pid, os_pid2} = Port.info(port2, :os_pid)
      System.cmd("kill", [Integer.to_string(os_pid2)])
      assert_receive {^port2, {:exit_status, 0}}, 30_000

      real_after = if File.exists?(real_store), do: File.read!(real_store), else: :absent
      assert real_after == real_before, "the real ~/.kyber store must never change"
    end
  end

  # ---------------------------------------------------------------- helpers

  defp fresh(tag) do
    Path.join(
      System.tmp_dir!(),
      "kyber-daemon-smoke-#{tag}-#{System.unique_integer([:positive])}"
    )
  end

  defp boot_daemon(binary, log, keyring, cwd) do
    Port.open(
      {:spawn_executable, binary},
      [
        :binary,
        :exit_status,
        {:line, 1024},
        cd: cwd,
        args: ["daemon", "--log", log, "--keyring", keyring]
      ]
    )
  end

  # register the OS-pid kill AT spawn time: Port.close does NOT terminate a
  # spawn_executable child (it inherits this run's stdout pipe and would hang
  # the run at EOF), so on ANY exit path we kill via the captured os_pid
  defp register_kill(port) do
    on_exit(fn ->
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> System.cmd("kill", [Integer.to_string(pid)])
        _ -> :ok
      end
    end)
  end

  defp view(binary, log) do
    {out, 0} = System.cmd(binary, ["--log", log, "view"], stderr_to_stdout: true)
    out
  end

  defp sent_lines(view_text) do
    view_text
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 =~ ~r/ sent /))
  end

  # bounded explicit polling: run `thunk` until `pred` holds or attempts run
  # out, yielding between tries with a timed receive (NEVER Process.sleep)
  defp poll_until(_thunk, _pred, 0), do: :timeout

  defp poll_until(thunk, pred, attempts) do
    result = thunk.()

    if pred.(result) do
      {:ok, result}
    else
      yield(50)
      poll_until(thunk, pred, attempts - 1)
    end
  end

  defp yield(ms) do
    receive do
    after
      ms -> :ok
    end
  end

  defp vault_bodies(vault) do
    [vault, "claims", "*.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&File.read!/1)
  end

  defp load_agent(keyring) do
    {:ok, seed} = Keys.load_agent_seed(keyring)
    seed
  end

  defp author8(seed_hex) do
    "ed25519:" <> hex = Keys.author_for_seed(seed_hex)
    String.slice(hex, 0, 8)
  end
end
