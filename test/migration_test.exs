defmodule Kyber.MigrationTest do
  use ExUnit.Case, async: false

  alias Kyber.{DurableStore, Harness, Keys, Migration, Wire}
  alias Rhizomatic.Delta

  # the T5 federation_test lifecycle pattern: migration tests need their OWN
  # isolated store per test (the store's whole set is inspected), so every
  # test's setup reboots :kyber on a fresh tmp log_path; setup_all only
  # captures the baseline env and restores it on exit — the real ~/.kyber is
  # never touched (config/test.exs points log_path/keyring_dir under tmp).
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
      "kyber-migration-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
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
    assert {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    fixture_dir = fresh_dir(System.tmp_dir!(), "legacy")
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

  # ------------------------------------------------------------- fixtures

  # AC8: byte-realistic against ~/repos/kyber/lib/kyber_beam/delta.ex —
  # `origin` is ALWAYS an object, `ts` an integer, `payload` arbitrary JSON,
  # `parent_id` a string or null.
  defp channel_origin(tag) do
    %{
      "type" => "channel",
      "channel" => "discord:#{tag}",
      "chat_id" => "chat:#{tag}",
      "sender_id" => "user:#{tag}"
    }
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
        "origin" => channel_origin("default"),
        "kind" => "message.received",
        "payload" => %{"text" => "hello"},
        "parent_id" => nil
      },
      fields
    )
  end

  defp legacy_line(map), do: JSON.encode!(map)

  defp write_fixture!(dir, name, lines) do
    path = Path.join(dir, name)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  # --------------------------------------------------------------- AC2/AC8

  test "AC2/AC8: a byte-realistic fixture migrates — archivist-signed, legacy/origin pointers, id matches, door re-admits",
       %{keyring_dir: keyring_dir, agent_seed: agent_seed, fixture_dir: fixture_dir} do
    origin_a = channel_origin("chan1")
    payload_a = %{"kind" => "memory", "text" => "hello world", "tags" => ["a", "b"]}
    map_a = legacy_map(%{"origin" => origin_a, "payload" => payload_a, "parent_id" => nil})

    map_b =
      legacy_map(%{
        "origin" => channel_origin("chan2"),
        "payload" => "a plain string payload",
        "parent_id" => map_a["id"]
      })

    path = write_fixture!(fixture_dir, "deltas.jsonl", [legacy_line(map_a), legacy_line(map_b)])

    assert {:ok, report} = Migration.migrate(path, keyring_dir)
    assert report == %{imported: 2, refused: [], skipped: 0, legacy_refused: []}

    assert {:ok, seed} = Keys.load_agent_seed(keyring_dir)
    assert {:ok, {claims_a, sig_a}} = Migration.translate_line(map_a, seed)
    id_a = Delta.id_hex(claims_a)

    # archivist author (the agent key loaded from keyring_dir)
    assert claims_a.author == Keys.author_for_seed(agent_seed)
    assert claims_a.author == Keys.author_for_seed(seed)

    assert Enum.member?(
             claims_a.pointers,
             %{role: "legacy", target: {:entity, "delta:" <> map_a["id"], "legacy"}}
           )

    assert Enum.member?(
             claims_a.pointers,
             %{role: "origin", target: {:string, JSON.encode!(origin_a)}}
           )

    assert Enum.member?(
             claims_a.pointers,
             %{role: "kind", target: {:string, "message.received"}}
           )

    assert Enum.member?(
             claims_a.pointers,
             %{role: "content", target: {:string, JSON.encode!(payload_a)}}
           )

    # parent_id was nil -> the pointer is omitted
    refute Enum.any?(claims_a.pointers, &(&1.role == "parent"))

    # the claim landed in the store keyed by its own content address
    {stored_claims_a, stored_sig_a} = Map.fetch!(DurableStore.set(), id_a)
    assert stored_claims_a == claims_a
    assert stored_sig_a == sig_a
    assert id_a == Delta.id_hex(stored_claims_a)

    # re-admission through the door succeeds — the archivist signature verifies
    assert :ok = DurableStore.append(Wire.envelope({stored_claims_a, stored_sig_a}))

    # AC8: fixture inspection — the exact legacy shape, byte-realistic
    [line1, line2] = File.read!(path) |> String.split("\n", trim: true)

    assert {:ok, decoded1} = JSON.decode(line1)
    assert decoded1["origin"]["type"] == "channel"
    assert is_map(decoded1["payload"])
    assert decoded1["parent_id"] == nil
    assert decoded1["kind"] == "message.received"
    assert is_integer(decoded1["ts"])

    assert {:ok, decoded2} = JSON.decode(line2)
    assert is_binary(decoded2["payload"])
    assert decoded2["parent_id"] == map_a["id"]
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: migrate is idempotent — a second run reports imported: 0; an in-file duplicate is skipped in run 1",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    map_a = legacy_map(%{"origin" => channel_origin("dup-a"), "payload" => %{"n" => 1}})

    map_b =
      legacy_map(%{
        "origin" => channel_origin("dup-b"),
        "payload" => "str",
        "parent_id" => map_a["id"]
      })

    dup_of_a = legacy_line(map_a)

    path =
      write_fixture!(fixture_dir, "deltas.jsonl", [
        legacy_line(map_a),
        legacy_line(map_b),
        dup_of_a
      ])

    assert {:ok, report1} = Migration.migrate(path, keyring_dir)
    assert report1 == %{imported: 2, refused: [], skipped: 1, legacy_refused: []}

    assert {:ok, report2} = Migration.migrate(path, keyring_dir)
    assert report2 == %{imported: 0, refused: [], skipped: 3, legacy_refused: []}
  end

  test "AC3: an empty legacy file migrates to an all-zeros report", %{
    keyring_dir: keyring_dir,
    fixture_dir: fixture_dir
  } do
    path = Path.join(fixture_dir, "empty.jsonl")
    File.write!(path, "")

    assert {:ok, report} = Migration.migrate(path, keyring_dir)
    assert report == %{imported: 0, refused: [], skipped: 0, legacy_refused: []}
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: malformed legacy lines are reported with exact 1-based line numbers, never fatal",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    valid1 = legacy_map(%{"origin" => channel_origin("m1"), "payload" => %{"a" => 1}})
    non_json = "not-json-at-all {"
    missing_kind = legacy_map(%{"origin" => channel_origin("m2")}) |> Map.delete("kind")
    string_ts = legacy_map(%{"origin" => channel_origin("m3")}) |> Map.put("ts", "not-a-number")
    valid2 = legacy_map(%{"origin" => channel_origin("m4"), "payload" => %{"b" => 2}})

    lines = [
      legacy_line(valid1),
      non_json,
      legacy_line(missing_kind),
      legacy_line(string_ts),
      legacy_line(valid2)
    ]

    path = write_fixture!(fixture_dir, "deltas.jsonl", lines)

    assert {:ok, report} = Migration.migrate(path, keyring_dir)
    assert report == %{imported: 2, refused: [], skipped: 0, legacy_refused: [2, 3, 4]}

    assert DurableStore.set() |> Map.keys() |> length() == 2
  end

  test "P5: a non-binary legacy id in the FILE is legacy_refused, never imported (no fabricated attestation)",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    bad = legacy_line(%{"id" => 123, "ts" => 1, "kind" => "k"})
    good = legacy_line(legacy_map(%{"kind" => "message.received"}))
    path = write_fixture!(fixture_dir, "deltas.jsonl", [bad, good])

    assert {:ok, report} = Migration.migrate(path, keyring_dir)
    assert report == %{imported: 1, refused: [], skipped: 0, legacy_refused: [1]}
  end

  test "P5: blank lines are skipped — a trailing \\n\\n reports NO phantom legacy_refused",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    line = legacy_line(legacy_map(%{"kind" => "message.received"}))
    path = Path.join(fixture_dir, "deltas.jsonl")
    File.write!(path, line <> "\n\n\n")

    assert {:ok, report} = Migration.migrate(path, keyring_dir)
    assert report == %{imported: 1, refused: [], skipped: 0, legacy_refused: []}
  end

  test "P5: error paths — missing seed, missing legacy file, and precedence",
       %{keyring_dir: keyring_dir, fixture_dir: fixture_dir} do
    line = legacy_line(legacy_map(%{"kind" => "message.received"}))

    # missing legacy path -> tagged tuple, never a crash
    missing = Path.join(fixture_dir, "no-such-file.jsonl")
    assert {:error, {:no_legacy_log, ^missing}} = Migration.migrate(missing, keyring_dir)

    # missing agent.seed (KYBER_SEED unset) -> :no_agent_seed
    empty_keyring = Path.join(fixture_dir, "empty-keyring")
    path = write_fixture!(fixture_dir, "deltas.jsonl", [line])
    assert {:error, :no_agent_seed} = Migration.migrate(path, empty_keyring)

    # precedence: missing seed wins over missing file (the with-chain order)
    assert {:error, :no_agent_seed} = Migration.migrate(missing, empty_keyring)
  end

  test "P5: store-down wins over a missing seed (guard-first precedence)",
       %{log_path: log_path} do
    :ok = stop_app()
    assert {:error, :store_not_running} = Migration.migrate("/nonexistent", "/nonexistent")

    boot_on(log_path)
    assert is_list(Harness.view())
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: store-down is a tagged tuple, never a crash", %{
    keyring_dir: keyring_dir,
    log_path: log_path,
    fixture_dir: fixture_dir
  } do
    path =
      write_fixture!(fixture_dir, "deltas.jsonl", [
        legacy_line(legacy_map(%{"origin" => channel_origin("down")}))
      ])

    :ok = stop_app()

    assert {:error, :store_not_running} = Migration.migrate(path, keyring_dir)

    # re-boot before returning: no later test may see a stopped store
    boot_on(log_path)
    assert is_list(Harness.view())
  end

  # ------------------------------------------------------------------ AC6

  test "AC6: translate_line/2 is pure and total — the pinned claim shape, all five pointers in order" do
    seed = String.duplicate("11", 32)
    origin = channel_origin("unit")
    payload = %{"note" => "hi"}

    legacy =
      legacy_map(%{
        "origin" => origin,
        "kind" => "memory.saved",
        "payload" => payload,
        "parent_id" => "parent-id-1"
      })

    assert {:ok, {claims, sig}} = Migration.translate_line(legacy, seed)
    assert is_binary(sig)
    assert claims.author == Keys.author_for_seed(seed)
    assert is_float(claims.timestamp)

    assert claims.pointers == [
             %{role: "legacy", target: {:entity, "delta:" <> legacy["id"], "legacy"}},
             %{role: "kind", target: {:string, "memory.saved"}},
             %{role: "origin", target: {:string, JSON.encode!(origin)}},
             %{role: "parent", target: {:string, "parent-id-1"}},
             %{role: "content", target: {:string, JSON.encode!(payload)}}
           ]

    # deterministic over the decoded term: same decoded map + same seed ->
    # same claims -> same id (the idempotency foundation)
    assert {:ok, {claims2, sig2}} = Migration.translate_line(legacy, seed)
    assert claims2 == claims
    assert sig2 == sig
  end

  test "AC6: optional fields absent or null are omitted from pointers" do
    seed = String.duplicate("22", 32)

    legacy =
      legacy_map(%{
        "origin" => nil,
        "kind" => "message.received",
        "payload" => nil,
        "parent_id" => nil
      })

    assert {:ok, {claims, _sig}} = Migration.translate_line(legacy, seed)
    assert Enum.map(claims.pointers, & &1.role) == ["legacy", "kind"]

    # absent (never present as a key at all) behaves identically to null
    absent_legacy = legacy |> Map.delete("origin") |> Map.delete("payload")
    assert {:ok, {claims2, _sig2}} = Migration.translate_line(absent_legacy, seed)
    assert claims2 == claims
  end

  test "AC6: the origin object is embedded as an encoded string, never a bare map" do
    seed = String.duplicate("33", 32)
    origin = channel_origin("embed")
    legacy = legacy_map(%{"origin" => origin})

    assert {:ok, {claims, _sig}} = Migration.translate_line(legacy, seed)
    origin_pointer = Enum.find(claims.pointers, &(&1.role == "origin"))
    assert {:string, encoded} = origin_pointer.target
    assert is_binary(encoded)
    assert JSON.decode!(encoded) == origin
  end

  test "AC6: ts coercion — integer ts becomes an exact float; string/null/true ts are refused, never a raise" do
    seed = String.duplicate("44", 32)

    int_legacy = legacy_map(%{"ts" => 1_700_000_000_123})
    assert {:ok, {claims, _sig}} = Migration.translate_line(int_legacy, seed)
    assert claims.timestamp === 1_700_000_000_123.0

    for bad_ts <- ["not-a-number", nil, true] do
      legacy = legacy_map(%{"ts" => bad_ts})
      assert Migration.translate_line(legacy, seed) == {:error, :timestamp_not_a_number}
    end
  end

  test "AC6: refusals happen BEFORE signing — a non-string kind is refused, never signed" do
    seed = String.duplicate("55", 32)
    legacy = legacy_map(%{"kind" => 123})

    # the value-type check refuses earlier than Delta.validate — the pin's
    # guarantee (never sign unvalidated claims) holds either way; the tag is
    # migration's own (P5: value-type validation)
    assert {:error, :invalid_legacy_kind} = Migration.translate_line(legacy, seed)
  end

  test "AC6: refusal tags — missing required keys and non-map input" do
    seed = String.duplicate("66", 32)

    assert {:error, {:missing_key, :legacy, "id"}} =
             Migration.translate_line(%{"ts" => 1, "kind" => "k"}, seed)

    assert {:error, {:missing_key, :legacy, "ts"}} =
             Migration.translate_line(%{"id" => "x", "kind" => "k"}, seed)

    assert {:error, {:missing_key, :legacy, "kind"}} =
             Migration.translate_line(%{"id" => "x", "ts" => 1}, seed)

    assert {:error, :malformed_legacy} = Migration.translate_line("not a map", seed)
    assert {:error, :malformed_legacy} = Migration.translate_line([1, 2, 3], seed)
    assert {:error, :malformed_legacy} = Migration.translate_line(nil, seed)

    # P5 medium finding 1: value-type validation — a non-string id is REFUSED,
    # never repaired into a fabricated entity id
    assert {:error, :invalid_legacy_id} =
             Migration.translate_line(%{"id" => 123, "ts" => 1, "kind" => "k"}, seed)

    assert {:error, :invalid_legacy_id} =
             Migration.translate_line(%{"id" => "not-hex", "ts" => 1, "kind" => "k"}, seed)

    assert {:error, :invalid_legacy_kind} =
             Migration.translate_line(
               %{"id" => String.duplicate("ab", 16), "ts" => 1, "kind" => 5},
               seed
             )
  end
end
