defmodule Kyber.CLIChannelTest do
  @moduledoc """
  T14i — the CLI preflight arms (N4/H6/H9/M5/L8): the THIRD preflight
  outcome (recognized, non-booting — `kyber tui` never boots the store),
  the channel daemon boot surface (`--loop reactor` / `--profile` /
  `--operator-seed-env` / `--channel-socket` with the L8 coupling), the
  `kyber discord` command class (H9 — argv shapes, the `--token <value>`
  exit-2 refusal, the profile-mandatory refusal), and the ESCRIPT-LEVEL
  witness that `kyber tui` boots NOTHING (H6 — the AC9 smoke pattern).
  """
  use ExUnit.Case, async: false

  alias Kyber.{CLI, DurableStore, Keys}

  @human_seed String.duplicate("cd", 32)

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
      "kyber-clich-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
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
      Kyber.Daemon.stop()
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, log_path: log_path}
  end


  # --------------------------------------------- T14i preflight arms (N4/H6/H9)

  test "T14i: the TUI is a RECOGNIZED, NON-BOOTING command — never a usage error, never a boot",
       %{log_path: log_path} do
    # recognized: the clean one-liner (no daemon on this log), NOT the usage block
    sock = log_path <> ".sock"

    assert {:error, message} = CLI.run(["tui", "--log", log_path])
    assert message == "daemon not running on #{sock}"

    # the TUI-scoped --socket opt (M14)
    assert {:error, message2} = CLI.run(["tui", "--socket", sock])
    assert message2 == "daemon not running on #{sock}"

    # malformed tui argv is still a usage error
    assert {:error, :usage, _} = CLI.run(["tui", "--bogus"])
  end

  test "T14i: with the store DOWN the TUI still does not boot — it answers the clean one-liner",
       %{log_path: log_path} do
    stop_app()

    assert {:error, message} = CLI.run(["tui", "--log", log_path])
    assert message == "daemon not running on #{log_path}.sock"

    # no store was booted (a booting command would have failed differently)
    assert Process.whereis(DurableStore) == nil

    boot_on(log_path)
  end

  test "T14i N4/L8: --channel-socket requires --loop reactor — usage exit 2; the channel daemon argv shapes are pinned",
       %{keyring_dir: keyring_dir, log_path: log_path} do
    # L8: --channel-socket WITHOUT --loop reactor is a usage error
    assert {:error, :usage, _} =
             CLI.run(["daemon", "--log", log_path, "--keyring", keyring_dir, "--channel-socket"])

    # a bare --loop with a non-reactor value is a usage error
    assert {:error, :usage, _} =
             CLI.run(["daemon", "--log", log_path, "--keyring", keyring_dir, "--loop", "ack"])

    # --operator-seed-env with a garbage env value: usage exit 2 (M5)
    System.put_env("T14I_GARBAGE_SEED", "not-hex!")
    on_exit(fn -> System.delete_env("T14I_GARBAGE_SEED") end)

    assert {:error, :usage, _} =
             CLI.run([
               "daemon",
               "--log",
               log_path,
               "--keyring",
               keyring_dir,
               "--loop",
               "reactor",
               "--operator-seed-env",
               "T14I_GARBAGE_SEED"
             ])

    # H7: --profile without an operator seed refuses boot (the boot_context
    # {_name, nil} refusal — the same helper attach uses)
    assert {:error, "unknown profile: channel:discord"} =
             CLI.run([
               "daemon",
               "--log",
               log_path,
               "--keyring",
               keyring_dir,
               "--loop",
               "reactor",
               "--profile",
               "channel:discord"
             ])
  end

  test "T14i N4: the channel daemon boots via the CLI — --loop reactor + --profile + --operator-seed-env + --channel-socket",
       %{keyring_dir: keyring_dir, log_path: log_path} do
    System.put_env("T14I_OPERATOR_SEED", String.duplicate("7f", 32))
    on_exit(fn -> System.delete_env("T14I_OPERATOR_SEED") end)

    assert {:ok, {:daemon, line, pid}} =
             CLI.run([
               "daemon",
               "--log",
               log_path,
               "--keyring",
               keyring_dir,
               "--loop",
               "reactor",
               "--operator-seed-env",
               "T14I_OPERATOR_SEED",
               "--channel-socket"
             ])

    assert is_pid(pid)
    assert line == "daemon running on #{log_path}"
    assert File.exists?(log_path <> ".sock")

    assert {:ok, %{"ok" => true, "status" => _}} =
             Kyber.CLI.TUI.request(log_path <> ".sock", %{"verb" => "status"})

    assert :ok = Kyber.Daemon.stop()
  end

  test "T14i H9: the discord command class — argv shapes, the --token exit-2 refusal, the profile-mandatory refusal",
       %{keyring_dir: keyring_dir, log_path: log_path} do
    base = ["discord", "--server", "999", "--token-env", "T14I_TOKEN", "--log", log_path, "--keyring", keyring_dir]

    # a token VALUE on argv is a usage error, exit 2 (ps-visible — D2)
    assert {:error, :usage, _} =
             CLI.run([
               "discord",
               "--server",
               "999",
               "--token",
               "SECRET_VALUE",
               "--log",
               log_path,
               "--keyring",
               keyring_dir
             ])

    # missing --server / --token-env: usage
    assert {:error, :usage, _} =
             CLI.run(["discord", "--log", log_path, "--keyring", keyring_dir])

    assert {:error, :usage, _} =
             CLI.run(["discord", "--server", "999", "--log", log_path, "--keyring", keyring_dir])

    # the profile-mandatory refusal (H9): profile-less gateway boot refuses
    System.put_env("T14I_TOKEN", "tok")
    System.put_env("T14I_OPERATOR_SEED", String.duplicate("7f", 32))
    on_exit(fn ->
      System.delete_env("T14I_TOKEN")
      System.delete_env("T14I_OPERATOR_SEED")
    end)

    assert {:error, "gateway requires a profile"} = CLI.run(base)

    # profile-without-seed-env: the H7 refusal (the same {:unknown_profile, _} family)
    assert {:error, "unknown profile: channel:discord"} =
             CLI.run(base ++ ["--profile", "channel:discord"])

    # a missing token env: fail-closed boot error (D2 — no default, no retry)
    assert {:error, "no discord token: T14I_MISSING"} =
             CLI.run([
               "discord",
               "--server",
               "999",
               "--token-env",
               "T14I_MISSING",
               "--log",
               log_path,
               "--keyring",
               keyring_dir,
               "--profile",
               "p",
               "--operator-seed-env",
               "T14I_OPERATOR_SEED"
             ])

    # a garbage operator-seed env value: usage exit 2 (M5) even on the
    # discord arm
    System.put_env("T14I_GARBAGE", "zzz")
    on_exit(fn -> System.delete_env("T14I_GARBAGE") end)

    assert {:error, :usage, _} =
             CLI.run(
               ["discord", "--server", "999", "--token-env", "T14I_TOKEN", "--log", log_path, "--keyring", keyring_dir,
                "--profile", "p", "--operator-seed-env", "T14I_GARBAGE"]
             )
  end

  # H6: the ESCRIPT-LEVEL witness — `kyber tui` boots NOTHING (the
  # second-store trap is VM-local-registered-name-guarded only; the escript
  # runs a separate VM, so the witness must be built and driven via
  # System.cmd). Same KYBER_SMOKE=1 gating as the AC9 smoke pattern.
  @tag :smoke
  test "T14i H6: escript smoke — `kyber tui` boots nothing and never touches the real ~/.kyber" do
    if System.get_env("KYBER_SMOKE") != "1" do
      IO.puts("skipped: set KYBER_SMOKE=1 to run the escript smoke")
    else
      root = File.cwd!()
      binary = Path.join(root, "kyber")
      on_exit(fn -> File.rm(binary) end)

      {build_out, build_code} =
        System.cmd("mix", ["escript.build"], cd: root, stderr_to_stdout: true)

      assert build_code == 0, "escript.build failed: #{build_out}"

      real_store = Path.join(System.user_home!(), ".kyber/store.jsonl")
      real_before = if File.exists?(real_store), do: File.read!(real_store), else: :absent

      # 1. `kyber tui` (no daemon running): the clean one-liner, exit 1 —
      #    NOT the "store failed to start" boot path, no usage block
      {out, code} = System.cmd(binary, ["tui"], stderr_to_stdout: true)
      assert code == 1, "`kyber tui` must exit 1 with no daemon, got #{code}: #{out}"
      assert out =~ "daemon not running on", "expected the clean one-liner, got: #{out}"
      refute out =~ "store failed to start", "the TUI must never boot the store: #{out}"

      real_after = if File.exists?(real_store), do: File.read!(real_store), else: :absent
      assert real_after == real_before, "the real ~/.kyber store must never change in the smoke"

      # 2. `kyber tui --log <existing-log>` against a daemon-less log: the
      #    same one-liner AND the log's bytes are untouched (no replay, no
      #    second store, no checkpoint)
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      tmp_log = Path.join(System.tmp_dir!(), "kyber-t14i-tui-smoke-#{uniq}.jsonl")
      File.write!(tmp_log, "{\"probe\":true}\n")
      on_exit(fn -> File.rm(tmp_log) end)

      {out2, code2} = System.cmd(binary, ["tui", "--log", tmp_log], stderr_to_stdout: true)
      assert code2 == 1, "got #{code2}: #{out2}"
      assert out2 =~ "daemon not running on"
      assert File.read!(tmp_log) == "{\"probe\":true}\n", "the log's bytes must be untouched"

      # 3. a malformed tui argv never boots either (the third-class preflight)
      {out3, code3} = System.cmd(binary, ["tui", "--bogus"], stderr_to_stdout: true)
      assert code3 == 2, "malformed tui argv must be usage exit 2, got #{code3}: #{out3}"
      assert out3 =~ "<command> [args]"
    end
  end
end
