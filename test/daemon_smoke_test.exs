defmodule Kyber.DaemonSmokeTest do
  use ExUnit.Case, async: false

  alias Kyber.Keys

  @moduletag :smoke
  @moduletag timeout: 300_000

  @human_seed String.duplicate("cd", 32)

  # The T10 operational smoke (AC7's shape, machine-checked): build the REAL
  # escript, boot `kyber daemon` on a tmp store as a long-running OS process,
  # ingest a message.received through the CLI from a second process, watch
  # the loop close through the daemon's own narration (assert_receive on the
  # port — the pinned no-sleep waiting), SIGTERM, re-boot, prove no re-fire.
  #
  # Process hygiene is the T9 lesson, applied: the daemon is spawned via
  # Port.open (System.cmd would block forever on a blocking command), the
  # kill is registered as on_exit AT SPAWN TIME via the OS pid (Port.close
  # does NOT terminate spawn_executable children), and the daemon runs with
  # a tmp cwd so a crash dump could never land in the repo. Runs only with
  # KYBER_SMOKE=1; otherwise a no-op pass. Never touches the real ~/.kyber.
  test "T10 smoke: daemon lifecycle, the agent loop closing, re-boot idempotence (AC1/AC3/AC4/AC5)" do
    if System.get_env("KYBER_SMOKE") != "1" do
      IO.puts("skipped: set KYBER_SMOKE=1 to run the daemon smoke")
    else
      root = File.cwd!()
      binary = Path.join(root, "kyber")
      on_exit(fn -> File.rm(binary) end)

      {build_out, build_code} =
        System.cmd("mix", ["escript.build"], cd: root, stderr_to_stdout: true)

      assert build_code == 0, "escript.build failed: #{build_out}"

      base =
        Path.join(
          System.tmp_dir!(),
          "kyber-daemon-smoke-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
        )

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      key_dir = Path.join(base, "keyring")
      File.mkdir_p!(key_dir)
      assert :ok = Keys.import_human_seed(@human_seed, key_dir)
      assert {:ok, _agent_seed} = Keys.mint_agent_seed(key_dir)

      log = Path.join(base, "store.jsonl")
      lock = log <> ".lock"

      real_store = Path.join(System.user_home!(), ".kyber/store.jsonl")
      real_before = if File.exists?(real_store), do: File.read!(real_store), else: :absent

      # ---- AC8: a malformed daemon argv is usage exit 2 and NEVER boots
      never = Path.join(base, "never-created.jsonl")

      {out, code} =
        System.cmd(binary, ["daemon", "--log", never], stderr_to_stdout: true, cd: base)

      assert code == 2, "malformed daemon argv must be usage exit 2, got #{code}: #{out}"
      refute File.exists?(never), "a usage-error path must never boot/create a store"

      # ---- AC1: boot; the marker line; the lock carries the OS pid
      port1 = spawn_daemon(binary, base, log, key_dir)
      assert_receive {^port1, {:data, {:eol, marker}}}, 30_000
      assert marker == "daemon running on #{log}"

      {:os_pid, os1} = Port.info(port1, :os_pid)
      assert File.read!(lock) == Integer.to_string(os1)

      # ---- AC1: a second daemon on the SAME log — the clean one-liner, exit 1
      {refusal, refusal_code} =
        System.cmd(binary, ["daemon", "--log", log, "--keyring", key_dir],
          stderr_to_stdout: true,
          cd: base
        )

      assert refusal_code == 1, "second daemon must exit 1, got #{refusal_code}: #{refusal}"
      assert String.trim(refusal) == "daemon already running on #{log}"

      # ---- the loop closes: ingest via the CLI from a second OS process...
      source = %{
        "message_id" => "message:discord:smoke:1",
        "channel_id" => "channel:discord:smoke",
        "session_id" => "session:discord:smoke",
        "content" => "smoke hello daemon",
        "ts" => 1_754_512_345_678
      }

      source_path = Path.join(base, "source.json")
      File.write!(source_path, JSON.encode!(source))

      {ingest_out, ingest_code} =
        System.cmd(binary, ["--log", log, "ingest", source_path, "--keyring", key_dir],
          stderr_to_stdout: true,
          cd: base
        )

      assert ingest_code == 0, "ingest failed: #{ingest_out}"
      rid = String.trim(ingest_out)
      rid8 = String.slice(rid, 0, 8)

      # ...and the daemon narrates the close: claim lands -> handler fires ->
      # ack persists -> checkpoint. assert_receive via await_line — no sleep.
      await_line(port1, &(&1 == "dispatched received #{rid8}"))
      await_line(port1, &(&1 == "fired received +1"))
      "persisted sent " <> ack8 = await_line(port1, &String.starts_with?(&1, "persisted sent "))
      await_line(port1, &(&1 == "checkpoint 1"))

      # ---- AC4 + AC5 in the store: exactly one ack; NO watcher.tick ever
      # persists (the ticker demonstrably ran — it just fired the handler)
      {view_out, 0} = System.cmd(binary, ["--log", log, "view"], stderr_to_stdout: true, cd: base)
      assert [sent_line] = view_lines(view_out, " sent ")
      assert String.starts_with?(sent_line, ack8)
      assert view_lines(view_out, " tick ") == []

      # ---- AC7: the vault renders the conversation; the ack body is the
      # pinned verbatim reply
      vault = Path.join(base, "vault")
      {_render, 0} = System.cmd(binary, ["--log", log, "render", vault], cd: base)

      assert [ack_file] = files_with_role(vault, "sent")
      assert String.ends_with?(File.read!(ack_file), "ack #{rid}\n")
      assert [_received_file] = files_with_role(vault, "received")

      # ---- AC1: SIGTERM -> clean shutdown, exit 0, lock released, store intact
      {_, 0} = System.cmd("kill", [Integer.to_string(os1)])
      assert_receive {^port1, {:exit_status, 0}}, 30_000
      refute File.exists?(lock)

      # ---- AC3: re-boot resumes from the persisted checkpoint; ticks run;
      # nothing re-fires
      port2 = spawn_daemon(binary, base, log, key_dir)
      assert_receive {^port2, {:data, {:eol, marker2}}}, 30_000
      assert marker2 == "daemon running on #{log}"

      # the first resumed tick dispatches the trailing checkpoint line —
      # proof the ticker is live past the cursor
      await_line(port2, &String.starts_with?(&1, "dispatched checkpoint "))

      # two full view round-trips (each boots a VM — many 100ms ticks apart):
      # still exactly one ack, twice
      {view2, 0} = System.cmd(binary, ["--log", log, "view"], stderr_to_stdout: true, cd: base)
      assert [_one] = view_lines(view2, " sent ")
      {view3, 0} = System.cmd(binary, ["--log", log, "view"], stderr_to_stdout: true, cd: base)
      assert [only] = view_lines(view3, " sent ")
      assert String.starts_with?(only, ack8)

      # nothing fired on the re-booted daemon — drain its narration and look
      refute Enum.any?(drain_lines(port2), &String.starts_with?(&1, "fired "))

      # the vault still shows exactly one exchange
      {_refresh, 0} = System.cmd(binary, ["--log", log, "refresh", vault], cd: base)
      assert [_one_ack] = files_with_role(vault, "sent")
      assert [_one_received] = files_with_role(vault, "received")

      # ---- shut the re-boot down cleanly too; the real store never changed
      {:os_pid, os2} = Port.info(port2, :os_pid)
      {_, 0} = System.cmd("kill", [Integer.to_string(os2)])
      assert_receive {^port2, {:exit_status, 0}}, 30_000
      refute File.exists?(lock)

      real_after = if File.exists?(real_store), do: File.read!(real_store), else: :absent
      assert real_after == real_before, "the real ~/.kyber store must never change in the smoke"
    end
  end

  # ---------------------------------------------------------------- helpers

  defp spawn_daemon(binary, cwd, log, keyring) do
    port =
      Port.open(
        {:spawn_executable, binary},
        [
          :binary,
          :exit_status,
          {:line, 2048},
          cd: cwd,
          args: ["daemon", "--log", log, "--keyring", keyring, "--tick-ms", "100"]
        ]
      )

    # failure-atomic teardown, registered AT spawn: Port.close does not
    # terminate spawn_executable children; kill via the OS pid on ANY exit
    on_exit(fn ->
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> System.cmd("kill", [Integer.to_string(pid)], stderr_to_stdout: true)
        _ -> :ok
      end
    end)

    port
  end

  # bounded no-sleep waiting: consume the daemon's narration until the
  # predicate matches (irrelevant lines are skipped), flunk on silence
  defp await_line(port, pred, timeout \\ 20_000) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        if pred.(line), do: line, else: await_line(port, pred, timeout)
    after
      timeout -> flunk("timed out waiting for a daemon narration line")
    end
  end

  # non-blocking drain (receive-after-0 — explicit polling, never a sleep)
  defp drain_lines(port, acc \\ []) do
    receive do
      {^port, {:data, {:eol, line}}} -> drain_lines(port, [line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp view_lines(view_out, marker) do
    view_out |> String.split("\n", trim: true) |> Enum.filter(&String.contains?(&1, marker))
  end

  defp files_with_role(vault, role) do
    vault
    |> Path.join("claims/*.md")
    |> Path.wildcard()
    |> Enum.filter(fn f -> File.read!(f) =~ "\nrole: #{role}\n" end)
  end
end
