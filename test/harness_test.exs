defmodule Kyber.HarnessTest do
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, DurableStore, Harness, Keys, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678

  # the pinned T4 lifecycle: setup_all starts the app on the config/test.exs
  # tmp log_path + keyring dir (the real ~/.kyber is never touched), on_exit
  # stops it — mirroring test/application_test.exs's stop_app pattern. Every
  # test re-boots the app before returning (AC3/AC9) so no test sees a
  # stopped store mid-file, and the file-level on_exit guarantees the T2
  # suite's start_supervised!({DurableStore, path}) finds the name free.
  setup_all do
    # AC11: the keyring_dir override is live config — the env points under tmp
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    assert is_binary(keyring_dir)
    assert String.starts_with?(keyring_dir, System.tmp_dir!())

    home = System.user_home()
    real_human_seed = Path.join(home, ".kyber/human.seed")
    real_agent_seed = Path.join(home, ".kyber/agent.seed")
    real_kyber_state = {File.exists?(real_human_seed), File.exists?(real_agent_seed)}

    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))

    on_exit(fn -> stop_app() end)

    {:ok, keyring_dir: keyring_dir, real_kyber_state: real_kyber_state}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  # seeds come from the tmp keyring: a fresh subdir of the env keyring_dir per
  # test, human seed imported + agent seed minted in setup (AC11 exercises the
  # env override; nothing lands in the real ~/.kyber)
  setup %{keyring_dir: keyring_dir} do
    dir =
      Path.join(
        keyring_dir,
        "harness-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    assert :ok = Keys.import_human_seed(@human_seed, dir)
    assert {:ok, agent_seed} = Keys.mint_agent_seed(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, keyring_dir: dir, agent_seed: agent_seed}
  end

  defp source_event(suffix, n) do
    %{
      "message_id" => "message:discord:#{suffix}:#{n}",
      "channel_id" => "channel:discord:#{suffix}",
      "session_id" => "session:discord:#{suffix}",
      "content" => "hello from #{suffix}:#{n}"
    }
  end

  defp agent_event_map(suffix) do
    %{
      "response_delta_id" => "1e20" <> String.duplicate("00", 32),
      "out_message_id" => "message:discord:#{suffix}:out-1",
      "channel_id" => "channel:discord:#{suffix}",
      "content" => "the model's reply"
    }
  end

  defp view_by_id do
    Map.new(Harness.view(), &{Delta.id_hex(&1), &1})
  end

  # ------------------------------------------------------------------ AC2

  test "AC2: ingest persists {claims, sig} keyed by content address; the claim re-admits",
       %{keyring_dir: keyring_dir} do
    source = source_event("111111111111111111", 1) |> Map.put("ts", @ts * 1.0)

    assert {:ok, id} = Harness.ingest(source, keyring_dir)

    # the set value is {claims, sig} — atom-keyed claims, NOT a wire envelope
    assert {%{timestamp: timestamp, author: author, pointers: pointers}, sig} =
             Map.fetch!(DurableStore.set(), id)

    assert is_map_key(%{timestamp: timestamp, author: author, pointers: pointers}, :timestamp)
    refute is_map_key(%{timestamp: timestamp, author: author, pointers: pointers}, "id")

    # content address: id == Delta.id_hex(claims)
    claims = %{timestamp: timestamp, author: author, pointers: pointers}
    assert id == Delta.id_hex(claims)

    # the claim's author derives from the human seed (spec/01-events.md §2.1)
    assert author == Keys.author_for_seed(@human_seed)

    # re-admitting the rebuilt envelope through the door succeeds (verified)
    assert %{"id" => ^id, "claims" => _, "sig" => ^sig} = Wire.envelope({claims, sig})
    assert :ok = DurableStore.append(Wire.envelope({claims, sig}))
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: ingest survives a supervised restart — the claim is still there (replay)",
       %{keyring_dir: keyring_dir} do
    source = source_event("222222222222222222", 2)
    assert {:ok, id} = Harness.ingest(source, keyring_dir)

    :ok = stop_app()
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))

    # replay through the door rebuilt the set; the view contains the claim
    assert DeltaSet.member?(DurableStore.set(), id)
    assert Map.has_key?(view_by_id(), id)
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: agent_event signs with the AGENT key; the view shows both halves (union)",
       %{keyring_dir: keyring_dir, agent_seed: agent_seed} do
    assert {:ok, human_id} = Harness.ingest(source_event("333333333333333333", 3), keyring_dir)

    assert {:ok, agent_id} =
             Harness.agent_event(agent_event_map("333333333333333333"), keyring_dir)

    refute human_id == agent_id

    # response half persisted, signed by the agent key (the minted tmp seed)
    assert {agent_claims, _sig} = Map.fetch!(DurableStore.set(), agent_id)
    assert agent_claims.author == Keys.author_for_seed(agent_seed)

    # the loop's two halves, union: both claims in the view
    view = view_by_id()
    assert view[human_id].author == Keys.author_for_seed(@human_seed)
    assert view[agent_id].author == Keys.author_for_seed(agent_seed)

    # causally pinned: message.sent points caused_by the response delta
    assert Enum.any?(agent_claims.pointers, fn p ->
             p == %{
               role: "caused_by",
               target: {:delta, "1e20" <> String.duplicate("00", 32), nil}
             }
           end)
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: a second valid source shape flows through; malformed shapes are refused",
       %{keyring_dir: keyring_dir} do
    source_a = source_event("555555555555555555", 5)
    source_b = source_event("666666666666666666", 6)

    assert {:ok, id_a} = Harness.ingest(source_a, keyring_dir)
    assert {:ok, id_b} = Harness.ingest(source_b, keyring_dir)
    refute id_a == id_b

    view = view_by_id()
    assert Map.has_key?(view, id_a)
    assert Map.has_key?(view, id_b)
    before = length(Harness.view())

    # the map fields land in the claim's pointers exactly as Events translates
    assert Enum.any?(
             view[id_b].pointers,
             &(&1 == %{
                 role: "at",
                 target: {:entity, "channel:discord:666666666666666666", "messages"}
               })
           )

    assert Enum.any?(
             view[id_b].pointers,
             &(&1 == %{role: "content", target: {:string, "hello from 666666666666666666:6"}})
           )

    # missing key -> the missing_key tag
    assert {:error, {:missing_key, :source, "message_id"}} =
             Harness.ingest(%{"channel_id" => "c"}, keyring_dir)

    # unknown key -> the unknown_key tag (closed envelope, reject never repair)
    assert {:error, {:unknown_key, :source, "bogus"}} =
             Harness.ingest(Map.put(source_a, "bogus", 1), keyring_dir)

    # an atom-keyed map is refused defensively: the first required key is
    # reported missing — Map.fetch, never a destructuring MatchError
    assert {:error, {:missing_key, :source, "message_id"}} =
             Harness.ingest(%{message_id: "x"}, keyring_dir)

    # the agent half obeys the same contract
    assert {:error, {:missing_key, :source, "response_delta_id"}} =
             Harness.agent_event(%{"out_message_id" => "m"}, keyring_dir)

    assert {:error, {:unknown_key, :source, "bogus"}} =
             Harness.agent_event(
               Map.put(agent_event_map("666666666666666666"), "bogus", 1),
               keyring_dir
             )

    # effect: none of the refused shapes persisted anything
    assert length(Harness.view()) == before
  end

  # ------------------------------------------------------------------ AC6

  test "AC6: a missing keyring fails cleanly — two distinct errors, never a crash",
       %{keyring_dir: keyring_dir} do
    System.delete_env("KYBER_SEED")
    on_exit(fn -> System.delete_env("KYBER_SEED") end)

    before = length(Harness.view())

    missing_dir = Path.join(keyring_dir, "no-such-dir")
    refute File.exists?(missing_dir)

    assert {:error, {:keyring_dir_missing, ^missing_dir}} =
             Harness.ingest(source_event("777777777777777777", 7), missing_dir)

    empty_dir = Path.join(keyring_dir, "empty")
    File.mkdir_p!(empty_dir)
    on_exit(fn -> File.rm_rf(empty_dir) end)

    assert {:error, :no_human_seed} =
             Harness.ingest(source_event("777777777777777777", 7), empty_dir)

    # the agent half refuses cleanly too (load_agent_seed/1 is T1 behavior:
    # no dir distinction — the rev 2 two-error split is pinned on the HUMAN
    # side; missing dir and missing file both yield :no_agent_seed, and
    # KYBER_SEED must not be consulted by the pipeline either way)
    assert {:error, :no_agent_seed} =
             Harness.agent_event(agent_event_map("777777777777777777"), missing_dir)

    assert {:error, :no_agent_seed} =
             Harness.agent_event(agent_event_map("777777777777777777"), empty_dir)

    # effect: none of the refused ingests persisted anything
    assert length(Harness.view()) == before
  end

  # ------------------------------------------------------------------ AC7

  test "AC7: claim timestamp equals the source float exactly (===); the builder owns coercion",
       %{keyring_dir: keyring_dir} do
    float_ts = 1_754_512_345_678.25
    source = source_event("888888888888888888", 8) |> Map.put("ts", float_ts)
    assert {:ok, id} = Harness.ingest(source, keyring_dir)
    {claims, _sig} = Map.fetch!(DurableStore.set(), id)
    assert claims.timestamp === float_ts
    assert claims.timestamp == float_ts

    # integer input is coerced to float BY THE BUILDER per D14 (documented,
    # never harness-side coercion)
    int_ts = 1_754_512_345_679
    source_int = source_event("999999999999999999", 9) |> Map.put("ts", int_ts)
    assert {:ok, id_int} = Harness.ingest(source_int, keyring_dir)
    {claims_int, _sig} = Map.fetch!(DurableStore.set(), id_int)
    assert claims_int.timestamp === 1_754_512_345_679.0

    # no "ts" -> now as float
    source_now = source_event("101010101010101010", 10)
    assert {:ok, id_now} = Harness.ingest(source_now, keyring_dir)
    {claims_now, _sig} = Map.fetch!(DurableStore.set(), id_now)
    assert is_float(claims_now.timestamp)
  end

  # ------------------------------------------------------------------ AC9

  test "AC9: store-down is a tagged tuple, never a crash; the app is re-booted",
       %{keyring_dir: keyring_dir} do
    :ok = stop_app()

    assert {:error, :store_not_running} =
             Harness.ingest(source_event("121212121212121212", 12), keyring_dir)

    assert {:error, :store_not_running} =
             Harness.agent_event(agent_event_map("121212121212121212"), keyring_dir)

    # re-boot before returning: no later test may see a stopped store
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
    assert is_list(Harness.view())
  end

  test "P5: guard-first precedence — with the app stopped AND the source malformed, the store-down error wins",
       %{keyring_dir: keyring_dir} do
    :ok = stop_app()

    # missing required key + store down -> guard wins (documented, now pinned)
    assert {:error, :store_not_running} = Harness.ingest(%{}, keyring_dir)

    # re-boot before returning
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  test "P5: non-binary required values are refused by the builder/witness with a tagged tuple (never a crash)",
       %{keyring_dir: keyring_dir} do
    # an integer message_id passes PRESENCE validation and flows to the Events
    # builder, whose witness-backed Delta.validate refuses it — the pinned
    # guarantee is a tagged tuple, whatever upstream tag surfaces
    bad = Map.put(source_event("131313131313131313", 13), "message_id", 123)
    before = Harness.view()

    assert {:error, {:not_a_string, _}} = Harness.ingest(bad, keyring_dir)
    assert Harness.view() == before
  end

  # ------------------------------------------------------------------ AC10

  test "AC10: view/0 is deterministic and assertable — atom-keyed claims sorted by id_hex",
       %{keyring_dir: keyring_dir} do
    # self-sufficient: a view with at least one claim regardless of test order
    assert {:ok, _id} = Harness.ingest(source_event("131313131313131313", 13), keyring_dir)

    v1 = Harness.view()
    v2 = Harness.view()
    assert v1 == v2

    # sorted by id_hex (deterministic order)
    assert Enum.map(v1, &Delta.id_hex/1) == Enum.sort(Enum.map(v1, &Delta.id_hex/1))

    # atom-keyed claim maps, exactly the {claims, sig} values in the set
    set = DurableStore.set()
    assert v1 != []

    Enum.each(v1, fn claims ->
      assert is_map_key(claims, :timestamp)
      assert is_map_key(claims, :author)
      assert is_map_key(claims, :pointers)
      assert {_stored_claims, _sig} = Map.fetch!(set, Delta.id_hex(claims))
    end)
  end

  # ------------------------------------------------------------------ AC11

  test "AC11: keyring_dir wiring is live — seeds land in tmp, never in the real ~/.kyber",
       %{real_kyber_state: real_kyber_state} do
    # the env override is exercised by every test's setup (fresh subdir of the
    # env keyring_dir under tmp); re-assert the wiring here
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    assert String.starts_with?(keyring_dir, System.tmp_dir!())

    # nothing appeared in the real ~/.kyber during the run
    home = System.user_home()

    assert real_kyber_state ==
             {File.exists?(Path.join(home, ".kyber/human.seed")),
              File.exists?(Path.join(home, ".kyber/agent.seed"))}
  end
end
