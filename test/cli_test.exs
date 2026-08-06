defmodule Kyber.CLITest do
  use ExUnit.Case, async: false

  alias Kyber.{CLI, DurableStore, Keys}

  @human_seed String.duplicate("cd", 32)

  # the T5/T6/T7 lifecycle pattern (test/migration_test.exs, test/vault_test.exs):
  # cli tests inspect the WHOLE store, so every test gets its own isolated
  # store on a fresh tmp log_path (boot_on) and its own tmp keyring/fixture
  # dirs; setup_all only captures the baseline env and restores it on exit —
  # the real ~/.kyber is never touched (config/test.exs points log_path and
  # keyring_dir under tmp). Keyring seeding is Keys.import_human_seed in
  # setup — there is NO seed-import CLI command in T8.
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
      "kyber-cli-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  # stop -> reconfigure log_path -> boot: the pinned way this suite gets an
  # isolated, singleton DurableStore per scenario.
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

    fixture_dir = fresh_dir(System.tmp_dir!(), "fixtures")
    File.mkdir_p!(fixture_dir)

    on_exit(fn ->
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
      File.rm_rf(fixture_dir)
    end)

    {:ok,
     keyring_dir: key_dir, agent_seed: agent_seed, log_path: log_path, fixture_dir: fixture_dir}
  end

  # ------------------------------------------------------------------ fixtures

  defp source_map(fields) do
    Map.merge(
      %{
        "message_id" => "message:discord:cli:1",
        "channel_id" => "channel:discord:cli",
        "session_id" => "session:discord:cli",
        "content" => "hello cli"
      },
      fields
    )
  end

  defp write_source!(fixture_dir, name, fields) do
    path = Path.join(fixture_dir, name)
    File.write!(path, JSON.encode!(source_map(fields)))
    path
  end

  defp legacy_id do
    System.unique_integer([:positive])
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(32, "0")
  end

  defp legacy_map(fields) do
    Map.merge(
      %{
        "id" => legacy_id(),
        "ts" => 1_700_000_000_000,
        "origin" => %{
          "type" => "channel",
          "channel" => "discord:cli",
          "chat_id" => "chat:cli",
          "sender_id" => "user:cli"
        },
        "kind" => "message.received",
        "payload" => %{"text" => "hi"},
        "parent_id" => nil
      },
      fields
    )
  end

  defp write_legacy!(fixture_dir, name, maps) do
    path = Path.join(fixture_dir, name)
    lines = Enum.map(maps, &JSON.encode!/1)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp author8(seed_hex) do
    "ed25519:" <> hex = Keys.author_for_seed(seed_hex)
    String.slice(hex, 0, 8)
  end

  # ------------------------------------------------------------------ AC2

  test "AC2: run/1 is pure dispatch — status tuples for every command, never a halt/IO/boot" do
    assert {:ok, usage} = CLI.run([])
    assert is_binary(usage)
    assert {:ok, ^usage} = CLI.run(["help"])
    assert {:error, :usage, _} = CLI.run(["help", "extra"])
    assert {:error, :usage, _} = CLI.run(["bogus"])

    # --log is a global prefix ONLY — after the command it's a usage error
    assert {:error, :usage, _} = CLI.run(["view", "--log", "/tmp/x"])
    assert {:error, :usage, _} = CLI.run(["render"])

    assert {:ok, _} = CLI.run(["view"])
    assert {:error, _} = CLI.run(["ingest", "/nonexistent", "--keyring", "/nonexistent"])
    assert {:error, _} = CLI.run(["import", "/nonexistent"])
    assert {:error, _} = CLI.run(["migrate", "/nonexistent", "--keyring", "/nonexistent"])
    assert {:ok, _} = CLI.run(["export"])
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: ingest + view end-to-end — the view line is BYTE-EQUAL to the pinned format",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    # fresh store: zero claims -> zero lines
    assert {:ok, ""} = CLI.run(["view"])

    path = write_source!(fixture_dir, "source.json", %{"ts" => 1_754_512_345_678})

    assert {:ok, id} = CLI.run(["ingest", path, "--keyring", keyring_dir])
    assert is_binary(id)

    assert {:ok, text} = CLI.run(["view"])
    assert text == "#{id} received #{author8(@human_seed)} 1754512345678"
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: render + refresh end-to-end — files: 1, refresh is idempotent",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    path = write_source!(fixture_dir, "source.json", %{})
    assert {:ok, _id} = CLI.run(["ingest", path, "--keyring", keyring_dir])

    vault_dir = fresh_dir(System.tmp_dir!(), "vault")

    assert {:ok, %{files: 1}} = CLI.run(["render", vault_dir])
    assert File.dir?(Path.join(vault_dir, "claims"))

    assert {:ok, %{files: 1, unchanged: 1, overwritten: []}} = CLI.run(["refresh", vault_dir])

    File.rm_rf(vault_dir)
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: export/import round-trip across two stores; a second import is all skipped",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    path = write_source!(fixture_dir, "source.json", %{})
    assert {:ok, _id} = CLI.run(["ingest", path, "--keyring", keyring_dir])

    assert {:ok, wire_text} = CLI.run(["export"])
    assert is_binary(wire_text)
    refute String.ends_with?(wire_text, "\n")

    wire_path = Path.join(fixture_dir, "wire.jsonl")
    File.write!(wire_path, wire_text)

    log_dir_b = fresh_dir(System.tmp_dir!(), "store-b")
    boot_on(Path.join(log_dir_b, "store.jsonl"))

    assert {:ok, report1} = CLI.run(["import", wire_path])
    assert report1 == %{imported: 1, refused: [], skipped: 0}

    assert {:ok, report2} = CLI.run(["import", wire_path])
    assert report2 == %{imported: 0, refused: [], skipped: 1}

    File.rm_rf(log_dir_b)
  end

  # ------------------------------------------------------------------ AC6

  test "AC6: migrate a legacy fixture; re-run is idempotent (all skipped)",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    legacy = legacy_map(%{})
    path = write_legacy!(fixture_dir, "deltas.jsonl", [legacy])

    assert {:ok, report1} = CLI.run(["migrate", path, "--keyring", keyring_dir])
    assert report1 == %{imported: 1, refused: [], skipped: 0, legacy_refused: []}

    assert {:ok, report2} = CLI.run(["migrate", path, "--keyring", keyring_dir])
    assert report2 == %{imported: 0, refused: [], skipped: 1, legacy_refused: []}
  end

  # ------------------------------------------------------------------ AC7

  test "AC7: store-down view -> the clean one-liner, exit-1 status", %{log_path: log_path} do
    stop_app()
    assert {:error, "store not running"} = CLI.run(["view"])

    # re-boot before returning: no later test may see a stopped store
    boot_on(log_path)
  end

  test "AC7: a missing source file -> the clean one-liner",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    missing = Path.join(fixture_dir, "nope.json")
    refute File.exists?(missing)

    assert {:error, message} = CLI.run(["ingest", missing, "--keyring", keyring_dir])
    assert message == "no such file: #{missing}"

    assert {:error, message2} = CLI.run(["import", missing])
    assert message2 == "no such file: #{missing}"
  end

  test "AC7: unknown command / help <extra> -> usage exit 2; bare/help -> usage exit 0" do
    assert {:error, :usage, usage} = CLI.run(["bogus"])
    assert {:error, :usage, ^usage} = CLI.run(["help", "extra"])
    assert {:ok, ^usage} = CLI.run([])
    assert {:ok, ^usage} = CLI.run(["help"])
  end

  test "AC7: the human-seed/keyring/legacy-log/agent-seed/malformed one-liners are pinned",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    path = write_source!(fixture_dir, "source.json", %{})

    empty_keyring = fresh_dir(fixture_dir, "empty-keyring")
    File.mkdir_p!(empty_keyring)

    assert {:error, msg} = CLI.run(["ingest", path, "--keyring", empty_keyring])
    assert msg == "no human seed: #{empty_keyring}"

    missing_keyring = Path.join(fixture_dir, "no-such-keyring")
    refute File.exists?(missing_keyring)

    assert {:error, msg2} = CLI.run(["ingest", path, "--keyring", missing_keyring])
    assert msg2 == "keyring dir missing: #{missing_keyring}"

    no_legacy = Path.join(fixture_dir, "no-legacy.jsonl")
    refute File.exists?(no_legacy)

    assert {:error, msg3} = CLI.run(["migrate", no_legacy, "--keyring", keyring_dir])
    assert msg3 == "no legacy log: #{no_legacy}"

    prior_seed = System.get_env("KYBER_SEED")
    System.delete_env("KYBER_SEED")
    on_exit(fn -> if prior_seed, do: System.put_env("KYBER_SEED", prior_seed) end)

    legacy_path = write_legacy!(fixture_dir, "deltas.jsonl", [legacy_map(%{})])

    assert {:error, "no agent seed"} =
             CLI.run(["migrate", legacy_path, "--keyring", missing_keyring])

    malformed_path = Path.join(fixture_dir, "bad.json")
    File.write!(malformed_path, "not json {")

    assert {:error, "malformed source"} =
             CLI.run(["ingest", malformed_path, "--keyring", keyring_dir])

    non_map_path = Path.join(fixture_dir, "list.json")
    File.write!(non_map_path, JSON.encode!([1, 2, 3]))

    assert {:error, "malformed source"} =
             CLI.run(["ingest", non_map_path, "--keyring", keyring_dir])
  end

  # ------------------------------------------------- T9 serve/send (AC5)

  test "T9 AC5: serve_start binds and reports the actual port; send round-trips its status" do
    assert {:ok, {:serve, line, pid}} = CLI.serve_start(port: "0")
    on_exit(fn -> if Process.alive?(pid), do: Kyber.Peer.stop(pid) end)

    assert is_pid(pid)
    port = Kyber.Peer.port(pid)
    assert line == "listening on #{port}"

    # export (an empty store -> "") ships to the peer; the status prints verbatim
    assert {:ok, status} = CLI.run(["send", "localhost", Integer.to_string(port)])
    assert status == "ok imported=0 skipped=0 refused=0"

    assert :ok = Kyber.Peer.stop(pid)
  end

  test "T9 AC5: a send to an unlistened port -> the peer-unreachable one-liner" do
    assert {:ok, pid} = Kyber.Peer.start_link(port: 0)
    free_port = Kyber.Peer.port(pid)
    assert :ok = Kyber.Peer.stop(pid)
    assert {:error, message} = CLI.run(["send", "localhost", Integer.to_string(free_port)])
    assert message == "peer unreachable: localhost #{free_port}"
  end

  test "T9 AC5: a silent peer -> the peer-timeout one-liner, not a misleading unreachable (P5 taxonomy)" do
    # a FAKE listener (a real kyber peer always replies): accept, read the
    # frame, then hold the connection open WITHOUT replying — send_wire's
    # 5000ms recv times out -> {:error, :timeout} -> "peer timeout"
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      # read the frame, then HOLD the connection open — a second blocking recv
      # (the poll, never a sleep); the process owning the socket must not exit,
      # or the socket closes with it and send_wire sees :closed, not :timeout
      {:ok, _frame} = :gen_tcp.recv(sock, 0, 15_000)
      :gen_tcp.recv(sock, 0, 15_000)
      :ok = :gen_tcp.close(sock)
    end)

    assert {:error, message} = CLI.run(["send", "localhost", Integer.to_string(port)])
    assert message == "peer timeout: localhost #{port}"
  end

  test "T9 AC5: serve with a non-integer --port -> usage exit 2" do
    assert {:error, :usage, _usage} = CLI.run(["serve", "--port", "abc"])
    assert {:error, :usage, _usage} = CLI.run(["serve", "--port", "99999999"])
    assert {:error, :usage, _usage} = CLI.serve_start(port: "abc")
  end

  test "T9 AC5: a --port already in use -> the listen-failure one-liner" do
    assert {:ok, {:serve, _line, pid}} = CLI.serve_start(port: "0")
    on_exit(fn -> if Process.alive?(pid), do: Kyber.Peer.stop(pid) end)
    in_use = Kyber.Peer.port(pid)

    assert {:error, message} = CLI.run(["serve", "--port", Integer.to_string(in_use)])
    assert message =~ "listen failed"

    assert :ok = Kyber.Peer.stop(pid)
  end

  # ------------------------------------------------------------------ AC8

  # (AC8 is a repo-wide grep for the sleep primitive across test/ — no
  # test-local assertion needed; this suite polls state, it never waits on
  # a timer.)

  # ------------------------------------------------------------------ AC9

  # P5 finding 2: the AC9 smoke is a REPO ARTIFACT (no longer gate prose).
  # The escript's boot sequence (load -> put_env -> start) and the store-fail
  # trigger are structurally invisible in `mix test` (:kyber is already
  # loaded), so this test builds the REAL binary and drives it via
  # System.cmd — the load-clobber regression class (--log dead, real store
  # booted) has a machine-checkable pin. The build takes ~30-60s, so it runs
  # only with KYBER_SMOKE=1 (the gate's pinned invocation); otherwise it
  # passes as a no-op. It never touches the real ~/.kyber.
  @tag :smoke
  test "AC9: escript smoke — --log wins over the baked default; store-fail trigger; exit codes; pre-flight never boots",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    if System.get_env("KYBER_SMOKE") != "1" do
      IO.puts("skipped: set KYBER_SMOKE=1 to run the escript smoke")
    else
      root = File.cwd!()
      binary = Path.join(root, "kyber")
      on_exit(fn -> File.rm(binary) end)

      # 1. build the escript
      {build_out, build_code} =
        System.cmd("mix", ["escript.build"], cd: root, stderr_to_stdout: true)

      assert build_code == 0, "escript.build failed: #{build_out}"

      real_store = Path.join(System.user_home!(), ".kyber/store.jsonl")
      real_before = if File.exists?(real_store), do: File.read!(real_store), else: :absent

      # 2. the pre-flight pin (P5 finding 1): malformed argv NEVER boots —
      #    a stray post-command --log prints usage (exit 2) and creates NOTHING
      never_path = Path.join(fixture_dir, "never-created-store.jsonl")
      {out, code} = System.cmd(binary, ["view", "--log", never_path], stderr_to_stdout: true)
      assert code == 2, "stray --log must be usage exit 2, got #{code}: #{out}"
      assert String.contains?(out, "<command> [args]"), "expected the usage block, got: #{out}"
      refute File.exists?(never_path), "a usage-error path must never boot/create a store"

      {_out, code} = System.cmd(binary, ["--log"], stderr_to_stdout: true)
      assert code == 2, "a bare --log must be usage exit 2, got #{code}"

      # 3. seed a tmp store through the CLI's own ingest (full-argv smoke)
      source = %{
        "message_id" => "message:discord:smoke:1",
        "channel_id" => "channel:discord:smoke",
        "session_id" => "session:discord:smoke",
        "content" => "smoke hello",
        "ts" => 1_754_512_345_678
      }

      source_path = Path.join(fixture_dir, "smoke-source.json")
      File.write!(source_path, JSON.encode!(source))

      tmp_log = Path.join(fixture_dir, "smoke-store.jsonl")

      {ingest_out, ingest_code} =
        System.cmd(binary, ["--log", tmp_log, "ingest", source_path, "--keyring", keyring_dir],
          stderr_to_stdout: true
        )

      assert ingest_code == 0, "ingest smoke failed: #{ingest_out}"

      # 4. --log wins over the baked default: the seeded claim is visible via
      #    --log and the REAL store is untouched
      {view_out, view_code} =
        System.cmd(binary, ["--log", tmp_log, "view"], stderr_to_stdout: true)

      assert view_code == 0, "view smoke failed: #{view_out}"
      # the pinned line format (no content column): <id> <role> <author8> <ts>
      assert view_out =~ "received fc947730 1754512345678",
             "the seeded claim must render via --log: #{view_out}"

      real_after = if File.exists?(real_store), do: File.read!(real_store), else: :absent
      assert real_after == real_before, "the real ~/.kyber store must never change in the smoke"

      # 5. the store-fail trigger: a --log whose PARENT is a regular file
      #    (mkdir_p on the parent fails -> the boot failure one-liner, exit 1)
      blocker = Path.join(fixture_dir, "blocker")
      File.write!(blocker, "i am a file")
      bad_log = Path.join(blocker, "store.jsonl")

      {fail_out, fail_code} =
        System.cmd(binary, ["--log", bad_log, "view"], stderr_to_stdout: true)

      assert fail_code == 1, "the boot failure must exit 1, got #{fail_code}: #{fail_out}"
      assert fail_out =~ "store failed to start", "expected the clean one-liner: #{fail_out}"

      # 6. the pinned exit codes
      {help_out, help_code} = System.cmd(binary, ["help"], stderr_to_stdout: true)
      assert help_code == 0, "help must exit 0"
      assert help_out =~ "<command> [args]"

      {_out, bogus_code} = System.cmd(binary, ["bogus"], stderr_to_stdout: true)
      assert bogus_code == 2, "an unknown command must exit 2"

      # 7. federation over TCP (T9 AC6): spawn `serve` on an EMPTY serve-side
      #    store (a DIFFERENT --log from the seeded sender store — a shared
      #    --log would replay the claim at boot and the import would be all
      #    skipped). `serve` blocks forever, so it must be a Port (System.cmd
      #    would block); assert_receive the listening line (the pinned
      #    no-sleep polling), send the seeded store to it, then prove the
      #    claim LANDED in the serve-side store post-kill.
      serve_log = Path.join(fixture_dir, "serve-store.jsonl")

      serve_port =
        Port.open(
          {:spawn_executable, binary},
          [
            :binary,
            :exit_status,
            {:line, 1024},
            # P5 finding 3: the serve VM runs with a tmp cwd so a SIGTERM
            # crash dump lands OUTSIDE the repo (BEAM's default SIGTERM
            # disposition writes erl_crash.dump into the process CWD)
            cd: fixture_dir,
            args: ["--log", serve_log, "serve", "--port", "0"]
          ]
        )

      # P5 finding 2: register the kill AT Port.open time — Port.close does
      # not terminate spawn_executable children, so an assertion failure
      # between here and the inline kill would leak the serve process (which
      # inherits this test's stdout pipe and hangs the run at EOF); the
      # on_exit makes the teardown failure-atomic on ANY exit path
      on_exit(fn ->
        case Port.info(serve_port, :os_pid) do
          {:os_pid, pid} -> System.cmd("kill", [Integer.to_string(pid)])
          _ -> :ok
        end
      end)

      assert_receive {^serve_port, {:data, {:eol, listening}}}, 60_000
      assert [_, n_str] = Regex.run(~r/listening on (\d+)/, listening)
      n = String.to_integer(n_str)

      {send_out, send_code} =
        System.cmd(binary, ["--log", tmp_log, "send", "localhost", Integer.to_string(n)],
          stderr_to_stdout: true
        )

      assert send_code == 0, "send smoke failed: #{send_out}"
      assert send_out =~ "ok imported=1", "the peer must import the seeded claim: #{send_out}"

      # kill the serve — Port.close does NOT terminate spawn_executable children
      # (the OS process survives, inherits the test's stdout pipe, and hangs the
      # run at EOF); kill via the OS pid captured from the port
      {:os_pid, os_pid} = Port.info(serve_port, :os_pid)
      System.cmd("kill", [Integer.to_string(os_pid)])

      {serve_view, serve_view_code} =
        System.cmd(binary, ["--log", serve_log, "view"], stderr_to_stdout: true)

      assert serve_view_code == 0, "serve-side view failed: #{serve_view}"

      assert serve_view =~ "received fc947730 1754512345678",
             "the federated claim must have landed in the serve-side store: #{serve_view}"
    end
  end
end
