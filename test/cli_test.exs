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

  # ------------------------------------------------------------------ AC8

  # (AC8 is a repo-wide grep for the sleep primitive across test/ — no
  # test-local assertion needed; this suite polls state, it never waits on
  # a timer.)
end
