defmodule Kyber.DaemonSmokeTest do
  @moduledoc """
  The escript smoke (T10 — AC1/AC3/AC4 against the REAL binary): the daemon
  runs as a subprocess; a SEPARATE VM ingests the fixture event; the ack
  lands; the vault renders the exchange; SIGTERM releases the lock with
  exit 0; a re-boot does not re-fire; no daemon processes leak.

  Runs only with KYBER_SMOKE=1 (the pinned invocation); otherwise it passes
  as a no-op — same discipline as the T9 escript smoke. It NEVER touches the
  real ~/.kyber: every path is under a tmp dir, and `kyber daemon` refuses
  to boot without --log at all.

  Kill discipline (paid for in T9): daemons are killed via the os_pid from
  `Port.info(port, :os_pid)` — Port.close does NOT terminate the escript
  child and EOF-hangs the suite. The kill is registered with on_exit at
  spawn time. Daemon VMs run with a tmp cwd so crash dumps never land in
  the repo.
  """

  use ExUnit.Case, async: false

  @human_seed String.duplicate("ab", 32)

  @tag :smoke
  test "daemon smoke: boot → ingest (separate VM) → ack → vault → SIGTERM → re-boot, no re-fire, no leaks" do
    if System.get_env("KYBER_SMOKE") != "1" do
      IO.puts("skipped: set KYBER_SMOKE=1 to run the daemon escript smoke")
    else
      root = File.cwd!()
      binary = Path.join(root, "kyber")
      on_exit(fn -> File.rm(binary) end)

      {build_out, build_code} =
        System.cmd("mix", ["escript.build"], cd: root, stderr_to_stdout: true)

      assert build_code == 0, "escript.build failed: #{build_out}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "kyber-t10-smoke-#{System.unique_integer([:positive])}"
        )

      log = Path.join(tmp, "store.jsonl")
      keyring = Path.join(tmp, "keyring")
      vault = Path.join(tmp, "vault")
      cwd = Path.join(tmp, "cwd")
      File.mkdir_p!(keyring)
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, _agent_seed} = Kyber.Keys.mint_agent_seed(keyring)
      :ok = Kyber.Keys.import_human_seed(@human_seed, keyring)

      # ---- AC8: usage errors never boot, exit 2
      {out, code} = System.cmd(binary, ["daemon", "--keyring", keyring], cd: cwd)
      assert code == 2, "daemon without --log must be usage exit 2, got #{code}: #{out}"
      assert out =~ "<command> [args]"
      refute File.exists?(log), "a usage-error path must never boot/create the store"

      {out, code} = System.cmd(binary, ["--log", log, "daemon", "--bogus"], cd: cwd)
      assert code == 2, "malformed daemon argv must be usage exit 2, got #{code}: #{out}"
      refute File.exists?(log)

      # ---- AC1: boot the daemon as a subprocess
      {port, os_pid} = boot_daemon(binary, log, keyring, cwd)
      assert_port_output(port, "daemon running on #{log}", 15_000)

      lock = log <> ".daemon"
      assert File.exists?(lock)
      assert String.trim(File.read!(lock)) == "#{os_pid}"

      # ---- AC1: a second invocation on the SAME log refuses cleanly, exit 1
      {out, code} =
        System.cmd(binary, ["--log", log, "daemon", "--keyring", keyring], cd: cwd)

      assert code == 1, "second daemon must exit 1, got #{code}: #{out}"
      assert String.trim(out) == "daemon already running on #{log}"

      # ---- AC2/AC4: ingest a fixture event via a SEPARATE VM
      source_path = Path.join(tmp, "source.json")

      File.write!(
        source_path,
        JSON.encode!(%{
          "message_id" => "message:smoke:t10:1",
          "channel_id" => "channel:smoke:t10",
          "session_id" => "session:smoke:t10",
          "content" => "close the loop"
        })
      )

      {ingest_out, code} =
        System.cmd(binary, ["--log", log, "ingest", source_path, "--keyring", keyring], cd: cwd)

      received_id = String.trim(ingest_out)
      assert code == 0, "ingest failed: #{ingest_out}"

      # the claim lands, the handler fires, the ack persists (bounded polling)
      ack_line = "\"ack #{received_id}\""
      assert_poll(fn -> File.exists?(log) and File.read!(log) =~ ack_line end, 15_000)

      # the dispatch cursor persisted as data (a daemon.checkpoint claim)
      assert_poll(fn -> File.read!(log) =~ "\"role\":\"checkpoint\"" end, 15_000)

      assert Enum.count(log_lines(log), &(&1 =~ "\"role\":\"sent\"")) == 1

      # ---- the vault renders exactly one exchange
      {render_out, code} = System.cmd(binary, ["--log", log, "render", vault], cd: cwd)
      assert code == 0, "render failed: #{render_out}"

      rendered = rendered_claims(vault)
      assert Enum.count(rendered, &(&1 =~ "role: received")) == 1
      assert Enum.count(rendered, &(&1 =~ "role: sent")) == 1
      assert Enum.any?(rendered, &(&1 =~ "ack #{received_id}"))

      # ---- AC1: SIGTERM -> clean shutdown, the lock releases, exit 0; the
      # store is intact (at least the settled lines survive, in order)
      System.cmd("kill", ["-TERM", "#{os_pid}"])
      assert_port_exit(port, 0, 15_000)
      assert_poll(fn -> not File.exists?(lock) end, 5_000)
      assert_os_dead(os_pid)

      final_lines = log_lines(log)
      assert Enum.count(final_lines, &(&1 =~ "\"role\":\"sent\"")) == 1

      # ---- AC3: re-boot does NOT re-fire — well over two ticks, no new line
      {port2, os_pid2} = boot_daemon(binary, log, keyring, cwd)
      assert_port_output(port2, "daemon running on #{log}", 15_000)
      assert_stable_log(log, final_lines, 1_500)
      assert Enum.count(log_lines(log), &(&1 =~ "\"role\":\"sent\"")) == 1

      # the vault still shows exactly one exchange
      {refresh_out, code} = System.cmd(binary, ["--log", log, "refresh", vault], cd: cwd)
      assert code == 0, "refresh failed: #{refresh_out}"
      rendered = rendered_claims(vault)
      assert Enum.count(rendered, &(&1 =~ "role: received")) == 1
      assert Enum.count(rendered, &(&1 =~ "role: sent")) == 1

      # ---- clean stop of the second daemon; zero leaked processes
      System.cmd("kill", ["-TERM", "#{os_pid2}"])
      assert_port_exit(port2, 0, 15_000)
      assert_poll(fn -> not File.exists?(lock) end, 5_000)
      assert_os_dead(os_pid2)
    end
  end

  # ---------------------------------------------------------------- helpers

  # spawn the daemon; register the os_pid kill with on_exit AT SPAWN TIME —
  # Port.close does not terminate the escript child (T9's paid-for lesson)
  defp boot_daemon(binary, log, keyring, cwd) do
    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: String.to_charlist(cwd),
        args: ["--log", log, "daemon", "--keyring", keyring]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      kill_os(os_pid)
      if Port.info(port), do: Port.close(port)
    end)

    {port, os_pid}
  end

  defp kill_os(os_pid) do
    if os_alive?(os_pid) do
      System.cmd("kill", ["-TERM", "#{os_pid}"], stderr_to_stdout: true)

      if not wait_os_dead(os_pid, 5_000) do
        System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true)
        wait_os_dead(os_pid, 5_000)
      end
    end

    :ok
  end

  defp assert_os_dead(os_pid) do
    assert wait_os_dead(os_pid, 5_000), "os process #{os_pid} still alive — a leaked daemon"
  end

  defp wait_os_dead(os_pid, timeout_ms) do
    poll(fn -> not os_alive?(os_pid) end, deadline(timeout_ms))
  end

  defp os_alive?(os_pid) do
    case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  # a bounded wait for a needle in the daemon's stdout stream
  defp assert_port_output(port, needle, timeout_ms) do
    assert await_output(port, needle, "", deadline(timeout_ms)),
           "daemon never printed #{inspect(needle)}"
  end

  defp await_output(port, needle, acc, deadline_ms) do
    if acc =~ needle do
      true
    else
      receive do
        {^port, {:data, data}} ->
          await_output(port, needle, acc <> data, deadline_ms)

        {^port, {:exit_status, status}} ->
          raise "daemon exited (#{status}) before printing #{inspect(needle)}"
      after
        50 ->
          if System.monotonic_time(:millisecond) > deadline_ms do
            false
          else
            await_output(port, needle, acc, deadline_ms)
          end
      end
    end
  end

  defp assert_port_exit(port, status, timeout_ms) do
    receive do
      {^port, {:exit_status, ^status}} -> :ok
      {^port, {:exit_status, other}} -> flunk("daemon exited with #{other}, expected #{status}")
    after
      timeout_ms -> flunk("daemon did not exit within #{timeout_ms}ms")
    end
  end

  # bounded explicit polling — a timed receive, never Process.sleep
  defp assert_poll(fun, timeout_ms) do
    assert poll(fun, deadline(timeout_ms)), "assert_poll timed out"
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp poll(fun, deadline_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        false
      else
        receive do
        after
          50 -> poll(fun, deadline_ms)
        end
      end
    end
  end

  # watch the log for `window_ms` (well over two 200ms ticks), asserting the
  # line list never changes — a re-fired handler would append a second
  # message.sent, and any re-dispatch would append a checkpoint
  defp assert_stable_log(log, expected_lines, window_ms) do
    do_assert_stable_log(log, expected_lines, deadline(window_ms))
  end

  defp do_assert_stable_log(log, expected_lines, deadline_ms) do
    if log_lines(log) != expected_lines do
      flunk("the log changed after re-boot — a handler re-fired")
    else
      if System.monotonic_time(:millisecond) < deadline_ms do
        receive do
        after
          50 -> do_assert_stable_log(log, expected_lines, deadline_ms)
        end
      else
        :ok
      end
    end
  end

  defp log_lines(log) do
    if File.exists?(log) do
      log |> File.read!() |> String.split("\n", trim: true)
    else
      []
    end
  end

  defp rendered_claims(vault) do
    vault
    |> Path.join("claims/claim_*.md")
    |> Path.wildcard()
    |> Enum.map(&File.read!/1)
  end
end
