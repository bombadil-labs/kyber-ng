defmodule Kyber.VaultTest do
  use ExUnit.Case, async: false

  alias Kyber.{DurableStore, Harness, Keys, Migration, Vault, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678

  # the T5/T6 lifecycle pattern (test/migration_test.exs): vault tests inspect
  # the WHOLE store and the whole vault dir, so every test gets its OWN
  # isolated store on a fresh tmp log_path (boot_on) and its own tmp vault
  # dir; setup_all only captures the baseline env and restores it on exit —
  # the real ~/.kyber is never touched (config/test.exs points log_path and
  # keyring_dir under tmp).
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
      "kyber-vault-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  # stop -> reconfigure log_path -> boot: the pinned way this suite gets an
  # isolated, singleton DurableStore per scenario (two stores cannot coexist
  # on the global name).
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

    vault_dir = fresh_dir(System.tmp_dir!(), "vault")

    on_exit(fn ->
      stop_app()
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
      File.rm_rf(vault_dir)
    end)

    {:ok, keyring_dir: key_dir, agent_seed: agent_seed, log_path: log_path, vault_dir: vault_dir}
  end

  defp source_event(tag) do
    %{
      "message_id" => "message:discord:vault-#{tag}:1",
      "channel_id" => "channel:discord:vault-#{tag}",
      "session_id" => "session:discord:vault-#{tag}",
      "content" => "hello vault #{tag}"
    }
  end

  defp claims_path(vault_dir, id_hex), do: Path.join([vault_dir, "claims", "claim_#{id_hex}.md"])

  # hand-build, validate, sign and append a claim OUTSIDE the Events/Migration
  # builders — used only to exercise pointer/target shapes those builders
  # never emit (AC5's delta-ref and entity-ref content targets)
  defp append_custom!(claims, seed_hex) do
    assert {:ok, claims} = Delta.validate(claims)
    assert {:ok, sig} = Keys.sign(claims, seed_hex)
    envelope = Wire.envelope({claims, sig})
    assert :ok = DurableStore.append(envelope)
    Delta.id_hex(claims)
  end

  # ------------------------------------------------------------------ AC2

  test "AC2: golden fixture — a message_received claim renders byte-exact; a second render is byte-identical",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir} do
    source = %{
      "message_id" => "message:discord:golden:1",
      "channel_id" => "channel:discord:golden",
      "session_id" => "session:discord:golden",
      "content" => "hello golden fixture",
      "ts" => @ts * 1.0
    }

    assert {:ok, id} = Harness.ingest(source, keyring_dir)
    assert {claims, _sig} = Map.fetch!(DurableStore.set(), id)

    assert {:ok, %{files: 1}} = Vault.render(vault_dir)

    path = claims_path(vault_dir, id)
    assert File.exists?(path)

    # P5 finding 1 fix: the ENTIRE golden is a hardcoded byte literal — the
    # pointers JSON, the decimal timestamp, the id, and the author are all
    # fixed constants for this fixture (same seed, ts, and inputs), so a
    # systematic drift in Wire.claims_json / JSON.encode! / the renderer can
    # no longer shift both sides together. Computed once (via trusted
    # primitives) at review time and pinned here verbatim.
    golden =
      "---\n" <>
        "id: 1e2016979a92ebdbe039dbea08820a26f0820690f0bd1b9f1ea3fca4289f946fbd56\n" <>
        "author: ed25519:fc947730f49eb01427a66e050733294d9e520e545c7a27125a780634e0860a27\n" <>
        "timestamp: 1754512345678\n" <>
        "role: received\n" <>
        "pointers: [{\"role\":\"received\",\"target\":{\"context\":\"incoming\",\"id\":\"message:discord:golden:1\"}},{\"role\":\"at\",\"target\":{\"context\":\"messages\",\"id\":\"channel:discord:golden\"}},{\"role\":\"by\",\"target\":{\"context\":\"sent\",\"id\":\"human:fc947730f49eb01427a66e050733294d9e520e545c7a27125a780634e0860a27\"}},{\"role\":\"content\",\"target\":\"hello golden fixture\"},{\"role\":\"session\",\"target\":{\"context\":\"messages\",\"id\":\"session:discord:golden\"}}]\n" <>
        "---\n" <>
        "hello golden fixture\n"

    assert File.read!(path) == golden

    # a second render into a fresh dir is byte-identical (deterministic)
    vault_dir2 = fresh_dir(System.tmp_dir!(), "vault-again")
    on_exit(fn -> File.rm_rf(vault_dir2) end)

    assert {:ok, %{files: 1}} = Vault.render(vault_dir2)
    path2 = claims_path(vault_dir2, id)

    assert File.ls!(Path.join(vault_dir, "claims")) == File.ls!(Path.join(vault_dir2, "claims"))
    assert File.read!(path2) == File.read!(path)
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: idempotent refresh — unchanged == files, overwritten == [], second refresh reports the same",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir} do
    assert {:ok, id1} = Harness.ingest(source_event("a"), keyring_dir)
    assert {:ok, _id2} = Harness.ingest(source_event("b"), keyring_dir)

    assert {:ok, %{files: 2}} = Vault.render(vault_dir)

    assert {:ok, %{files: 2, unchanged: 2, overwritten: []}} = Vault.refresh(vault_dir)
    assert {:ok, %{files: 2, unchanged: 2, overwritten: []}} = Vault.refresh(vault_dir)

    {claims1, _sig} = Map.fetch!(DurableStore.set(), id1)
    pointers_json = claims1 |> Wire.claims_json() |> Map.fetch!("pointers") |> JSON.encode!()
    assert File.read!(claims_path(vault_dir, id1)) =~ pointers_json
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: foreign files are never touched; hand-edited claim files are overwritten and reported",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir} do
    assert {:ok, id} = Harness.ingest(source_event("c"), keyring_dir)
    assert {:ok, %{files: 1}} = Vault.render(vault_dir)

    foreign_path = Path.join(vault_dir, "notes.md")
    File.write!(foreign_path, "my own notes\n")

    claim_path = claims_path(vault_dir, id)
    original = File.read!(claim_path)
    File.write!(claim_path, "hand-edited content\n")

    assert {:ok, %{files: 1, unchanged: 0, overwritten: [^claim_path]}} = Vault.refresh(vault_dir)

    assert File.read!(claim_path) == original
    assert File.read!(foreign_path) == "my own notes\n"

    # a second refresh is idempotent again once the canonical bytes are back
    assert {:ok, %{files: 1, unchanged: 1, overwritten: []}} = Vault.refresh(vault_dir)
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: pinned frontmatter fields; T6-legacy role + payload body; wikilinks resolve; entity targets are plain text",
       %{keyring_dir: keyring_dir, agent_seed: agent_seed, vault_dir: vault_dir} do
    assert {:ok, id_recv} = Harness.ingest(source_event("d"), keyring_dir)

    legacy_dir = fresh_dir(System.tmp_dir!(), "legacy")
    File.mkdir_p!(legacy_dir)
    on_exit(fn -> File.rm_rf(legacy_dir) end)

    legacy_map = %{
      "id" => String.duplicate("ab", 16),
      "ts" => 1_700_000_000_000,
      "kind" => "message.received",
      "origin" => %{"type" => "channel"},
      "payload" => %{"text" => "legacy hello"},
      "parent_id" => nil
    }

    legacy_path = Path.join(legacy_dir, "deltas.jsonl")
    File.write!(legacy_path, JSON.encode!(legacy_map) <> "\n")

    assert {:ok, %{imported: 1}} = Migration.migrate(legacy_path, keyring_dir)
    assert {:ok, seed} = Keys.load_agent_seed(keyring_dir)
    assert {:ok, {legacy_claims, _sig}} = Migration.translate_line(legacy_map, seed)
    id_legacy = Delta.id_hex(legacy_claims)

    # synthetic claim: content pointer targets a DELTA ref (a claim address)
    link_claims = %{
      timestamp: 1.0,
      author: Keys.author_for_seed(agent_seed),
      pointers: [%{role: "content", target: {:delta, id_recv, nil}}]
    }

    id_link = append_custom!(link_claims, agent_seed)

    # synthetic claim: content pointer targets an ENTITY ref (never a claim address)
    entity_claims = %{
      timestamp: 1.0,
      author: Keys.author_for_seed(agent_seed),
      pointers: [%{role: "content", target: {:entity, "human:deadbeef", "profile"}}]
    }

    id_entity = append_custom!(entity_claims, agent_seed)

    assert {:ok, %{files: 4}} = Vault.render(vault_dir)

    recv_text = File.read!(claims_path(vault_dir, id_recv))
    assert recv_text =~ "id: #{id_recv}\n"
    assert recv_text =~ "role: received\n"

    legacy_text = File.read!(claims_path(vault_dir, id_legacy))
    assert legacy_text =~ "role: legacy\n"
    assert legacy_text =~ JSON.encode!(%{"text" => "legacy hello"})

    link_text = File.read!(claims_path(vault_dir, id_link))
    assert link_text =~ "[[claim_#{id_recv}]]"
    # the wikilink resolves: the target file actually exists in this vault
    assert File.exists?(claims_path(vault_dir, id_recv))

    entity_text = File.read!(claims_path(vault_dir, id_entity))
    refute entity_text =~ "[["
    assert entity_text =~ "human:deadbeef"

    # P5 finding 2: an absent delta ref renders the link — the lens shows
    # what the store SAYS (the door admits closure/id/sig, never ref-presence);
    # resolution is a SET property, guaranteed only for self-consistent sets.
    # Pinned as documented behavior, never silently hidden.
    absent_hex = String.duplicate("ee", 64)

    absent_claims = %{
      timestamp: 1_700_000_000_000.0,
      author: Keys.author_for_seed(String.duplicate("44", 32)),
      pointers: [
        %{role: "content", target: {:delta, absent_hex, "kyber"}},
        %{role: "session", target: {:string, "session:discord:vault"}}
      ]
    }

    id_absent = append_custom!(absent_claims, String.duplicate("44", 32))
    assert {:ok, %{files: 5}} = Vault.render(vault_dir)

    absent_text = File.read!(claims_path(vault_dir, id_absent))
    assert absent_text =~ "[[claim_#{absent_hex}]]"
    refute File.exists?(claims_path(vault_dir, absent_hex))
  end

  # ------------------------------------------------------------------ AC6

  test "AC6: cold-rebuild identity — render, stop, reboot on the SAME log, render into a fresh dir, byte-identical",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir, log_path: log_path} do
    assert {:ok, _id} = Harness.ingest(source_event("e"), keyring_dir)
    assert {:ok, %{files: 1}} = Vault.render(vault_dir)

    boot_on(log_path)

    vault_dir2 = fresh_dir(System.tmp_dir!(), "vault-rebuild")
    on_exit(fn -> File.rm_rf(vault_dir2) end)

    assert {:ok, %{files: 1}} = Vault.render(vault_dir2)

    assert File.ls!(Path.join(vault_dir, "claims")) == File.ls!(Path.join(vault_dir2, "claims"))
    [file] = File.ls!(Path.join(vault_dir, "claims"))

    assert File.read!(Path.join([vault_dir, "claims", file])) ==
             File.read!(Path.join([vault_dir2, "claims", file]))
  end

  # ------------------------------------------------------------------ AC7

  test "AC7: store-down is a tagged tuple for render AND refresh; the app is re-booted",
       %{vault_dir: vault_dir, log_path: log_path} do
    :ok = stop_app()

    assert {:error, :store_not_running} = Vault.render(vault_dir)
    assert {:error, :store_not_running} = Vault.refresh(vault_dir)

    boot_on(log_path)
    assert is_pid(Process.whereis(DurableStore))
  end

  # ------------------------------------------------------------------ P5

  test "P5: a read-only claims dir yields {:write_failed, path, reason} from BOTH render and refresh (never a raise)",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir, log_path: log_path} do
    source = %{
      "message_id" => "message:discord:ro:1",
      "channel_id" => "channel:discord:ro",
      "session_id" => "session:discord:ro",
      "content" => "hello ro"
    }

    assert {:ok, _id} = Harness.ingest(source, keyring_dir)

    # stage the failure: a read-only claims dir (mkdir_p! succeeds on the dir,
    # then File.write hits EACCES). A regular FILE at claims/ would instead
    # pre-empt into {:vault_dir_not_dir, ...} — mkdir_p! raises on a non-dir —
    # which is ALSO a pinned tagged tuple (the extra test below covers it).
    claims_dir = Path.join(vault_dir, "claims")
    File.mkdir_p!(claims_dir)
    File.chmod!(claims_dir, 0o500)

    assert {:error, {:write_failed, path, :eacces}} = Vault.render(vault_dir)
    assert String.ends_with?(path, ".md")
    assert Path.dirname(path) == claims_dir
    assert {:error, {:write_failed, _, :eacces}} = Vault.refresh(vault_dir)

    # restore permissions so the on_exit cleanup can rm_rf
    File.chmod!(claims_dir, 0o700)
    File.rm_rf(claims_dir)

    # sanity: a fresh render after the obstruction is gone works
    assert {:ok, %{files: 1}} = Vault.render(vault_dir)
    assert is_pid(Process.whereis(DurableStore))
  end

  test "P5: a regular FILE at vault_dir/claims is {:vault_dir_not_dir, path} — never a raise",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir} do
    source = %{
      "message_id" => "message:discord:ro2:1",
      "channel_id" => "channel:discord:ro2",
      "session_id" => "session:discord:ro2",
      "content" => "hello ro2"
    }

    assert {:ok, _id} = Harness.ingest(source, keyring_dir)

    claims_dir = Path.join(vault_dir, "claims")
    File.mkdir_p!(claims_dir)
    File.rm_rf(claims_dir)
    File.write!(claims_dir, "i am a file")

    assert {:error, {:vault_dir_not_dir, ^claims_dir}} = Vault.render(vault_dir)
    assert {:error, {:vault_dir_not_dir, ^claims_dir}} = Vault.refresh(vault_dir)

    File.rm(claims_dir)
    assert {:ok, %{files: 1}} = Vault.render(vault_dir)
    assert is_pid(Process.whereis(DurableStore))
  end

  # ---------------------------------------------------------------- extra

  test "a regular file at the vault dir path is a tagged tuple, never a raise",
       %{keyring_dir: keyring_dir, vault_dir: vault_dir} do
    assert {:ok, _id} = Harness.ingest(source_event("f"), keyring_dir)
    File.write!(vault_dir, "not a directory")

    assert {:error, {:vault_dir_not_dir, ^vault_dir}} = Vault.render(vault_dir)
  end
end
