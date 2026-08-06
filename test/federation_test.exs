defmodule Kyber.FederationTest do
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, DurableStore, Events, Federation, Harness, Keys, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)

  # the T4 harness_test lifecycle pattern, adapted: federation tests need
  # their OWN isolated store per test (export/0 enumerates the WHOLE store,
  # so cross-test leakage would break AC2's "empty store exports \"\""), so
  # (unlike harness_test's single shared setup_all boot) every test's setup
  # reboots :kyber on a fresh tmp log_path; setup_all only captures the
  # baseline env and restores it on exit — the real ~/.kyber is never
  # touched (config/test.exs points log_path/keyring_dir under tmp).
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
      "kyber-federation-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  # stop -> reconfigure log_path -> boot: the pinned way this suite gets an
  # isolated, singleton DurableStore per scenario (two stores cannot coexist
  # on the global name — AC3's cross-instance test is sequential boots)
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

  defp agent_event_map(suffix) do
    %{
      "response_delta_id" => "1e20" <> String.duplicate("00", 32),
      "out_message_id" => "message:discord:#{suffix}:out-1",
      "channel_id" => "channel:discord:#{suffix}",
      "content" => "the model's reply"
    }
  end

  defp encode_envelope(signed), do: encode_wire(Wire.envelope(signed))

  defp encode_wire(wire) do
    assert {:ok, json} = Wire.encode(wire)
    json
  end

  # the durable_store_test tamper pattern: flip a nibble in the sig — valid
  # JSON, valid envelope shape, signature that does not verify
  defp tamper_sig_field(wire) do
    <<c::binary-1, rest::binary>> = wire["sig"]
    flipped = if c == "0", do: "1", else: "0"
    %{wire | "sig" => flipped <> rest}
  end

  # ------------------------------------------------------------------ AC2

  test "AC2: export is deterministic, sorted by id_hex, no trailing newline; empty store exports \"\"",
       %{keyring_dir: keyring_dir} do
    assert {:ok, ""} = Federation.export()

    assert {:ok, id_a} = Harness.ingest(source_event("11111111111111111111", 1), keyring_dir)
    assert {:ok, id_b} = Harness.ingest(source_event("22222222222222222222", 2), keyring_dir)

    assert {:ok, text1} = Federation.export()
    assert {:ok, text2} = Federation.export()
    assert text1 == text2
    refute String.ends_with?(text1, "\n")

    lines = String.split(text1, "\n")
    assert length(lines) == 2

    ids =
      Enum.map(lines, fn line ->
        assert {:ok, envelope} = Wire.decode(line)
        envelope["id"]
      end)

    assert ids == Enum.sort(ids)
    assert ids == Enum.sort([id_a, id_b])
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: sequential singleton boots — export(A) round-trips into B; re-import dedups",
       %{keyring_dir: keyring_dir} do
    assert {:ok, human_id} = Harness.ingest(source_event("33333333333333333333", 3), keyring_dir)

    assert {:ok, agent_id} =
             Harness.agent_event(agent_event_map("33333333333333333333"), keyring_dir)

    refute human_id == agent_id

    assert {:ok, export_a} = Federation.export()
    view_a = Harness.view()

    log_dir_b = fresh_dir(System.tmp_dir!(), "store-b")
    boot_on(Path.join(log_dir_b, "store.jsonl"))

    assert {:ok, report} = Federation.import(export_a)
    assert report == %{imported: 2, refused: [], skipped: 0}

    set_b = DurableStore.set()
    assert DeltaSet.member?(set_b, human_id)
    assert DeltaSet.member?(set_b, agent_id)
    assert Harness.view() == view_a

    assert {:ok, report2} = Federation.import(export_a)
    assert report2 == %{imported: 0, refused: [], skipped: 2}

    File.rm_rf(log_dir_b)
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: byte-identical union round trip — including an integer-timestamp wire fixture",
       %{keyring_dir: keyring_dir} do
    assert {:ok, _id} = Harness.ingest(source_event("44444444444444444444", 4), keyring_dir)

    assert {:ok, _id2} =
             Harness.agent_event(agent_event_map("44444444444444444444"), keyring_dir)

    # the witness's blessed int->float point (Profile.parse_claims'
    # coerce_number): a foreign line whose wire "timestamp" is a bare JSON
    # integer parses to the SAME float the builder would emit, so it
    # re-exports byte-identically
    assert {:ok, {int_claims, int_sig}} =
             Events.message_received(
               @human_seed,
               1_754_512_345_680.0,
               "message:discord:55555555555555555555:5",
               "channel:discord:55555555555555555555",
               "session:discord:55555555555555555555",
               "hello int-ts"
             )

    int_ts_envelope =
      put_in(Wire.envelope({int_claims, int_sig}), ["claims", "timestamp"], 1_754_512_345_680)

    assert :ok = DurableStore.append(int_ts_envelope)

    assert {:ok, export_a} = Federation.export()

    log_dir_b = fresh_dir(System.tmp_dir!(), "store-b")
    boot_on(Path.join(log_dir_b, "store.jsonl"))

    assert {:ok, report} = Federation.import(export_a)
    assert report.imported == 3
    assert report.refused == []

    assert {:ok, export_b} = Federation.export()
    assert export_b == export_a

    File.rm_rf(log_dir_b)
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: torn/tampered/non-envelope lines are refused with line numbers; a foreign-authored claim imports" do
    assert {:ok, valid_signed} =
             Events.message_received(
               @human_seed,
               1_754_512_345_681.0,
               "message:discord:66666666666666666666:6",
               "channel:discord:66666666666666666666",
               "session:discord:66666666666666666666",
               "hello valid"
             )

    line1 = encode_envelope(valid_signed)

    assert {:ok, {tamper_claims, tamper_sig}} =
             Events.message_received(
               @human_seed,
               1_754_512_345_682.0,
               "message:discord:77777777777777777777:7",
               "channel:discord:77777777777777777777",
               "session:discord:77777777777777777777",
               "hello tampered"
             )

    line2 = Wire.envelope({tamper_claims, tamper_sig}) |> tamper_sig_field() |> encode_wire()

    line3 = "[]"

    foreign_seed = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    assert {:ok, foreign_signed} =
             Events.message_received(
               foreign_seed,
               1_754_512_345_683.0,
               "message:discord:88888888888888888888:8",
               "channel:discord:88888888888888888888",
               "session:discord:88888888888888888888",
               "hello from a peer"
             )

    line4 = encode_envelope(foreign_signed)

    assert {:ok, torn_signed} =
             Events.message_received(
               @human_seed,
               1_754_512_345_684.0,
               "message:discord:99999999999999999999:9",
               "channel:discord:99999999999999999999",
               "session:discord:99999999999999999999",
               "hello torn"
             )

    line5 = String.slice(encode_envelope(torn_signed), 0, 20)

    text = Enum.join([line1, line2, line3, line4, line5], "\n")

    assert {:ok, report} = Federation.import(text)
    assert report == %{imported: 2, refused: [2, 3, 5], skipped: 0}

    {foreign_claims, _foreign_sig} = foreign_signed
    assert DeltaSet.member?(DurableStore.set(), Delta.id_hex(foreign_claims))
  end

  # ------------------------------------------------------------------ AC6

  test "AC6: store-down is a tagged tuple, never a crash", %{log_path: log_path} do
    :ok = stop_app()

    assert {:error, :store_not_running} = Federation.export()
    assert {:error, :store_not_running} = Federation.import("irrelevant text")

    # re-boot before returning: no later test may see a stopped store
    boot_on(log_path)
    assert is_list(Harness.view())
  end

  # ------------------------------------------------------------------ AC7

  test "AC7: import_report is a live, store-owned observable — zeros initially, reset per import" do
    assert Federation.import_report() == %{imported: 0, refused: [], skipped: 0}

    assert {:ok, signed} =
             Events.message_received(
               @human_seed,
               1_754_512_345_690.0,
               "message:discord:aaaaaaaaaaaaaaaaaaaa:10",
               "channel:discord:aaaaaaaaaaaaaaaaaaaa",
               "session:discord:aaaaaaaaaaaaaaaaaaaa",
               "hello report"
             )

    line1 = encode_envelope(signed)
    line2 = "not json {"

    assert {:ok, report1} = Federation.import(Enum.join([line1, line2], "\n"))
    assert report1 == %{imported: 1, refused: [2], skipped: 0}
    assert Federation.import_report() == report1

    # a second, distinct import RESETS the observable — a duplicate here
    assert {:ok, report2} = Federation.import(line1)
    assert report2 == %{imported: 0, refused: [], skipped: 1}
    assert Federation.import_report() == report2
  end

  # ------------------------------------------------------------------ AC8

  test "AC8: a sink failure halts the import; input failures reported before it survive" do
    assert {:ok, seed_signed} =
             Events.message_received(
               @human_seed,
               1_754_512_345_700.0,
               "message:discord:bbbbbbbbbbbbbbbbbbbb:11",
               "channel:discord:bbbbbbbbbbbbbbbbbbbb",
               "session:discord:bbbbbbbbbbbbbbbbbbbb",
               "hello seed"
             )

    # forces the log device open, then closed behind the store's back (the
    # T2 AC9 technique) — the NEXT write attempt fails
    assert :ok = DurableStore.append(Wire.envelope(seed_signed))
    state = :sys.get_state(DurableStore)
    assert :ok = File.close(state.io)

    line1 = "[]"

    assert {:ok, {fail_claims, fail_sig}} =
             Events.message_received(
               @human_seed,
               1_754_512_345_701.0,
               "message:discord:cccccccccccccccccccc:12",
               "channel:discord:cccccccccccccccccccc",
               "session:discord:cccccccccccccccccccc",
               "hello sink failure"
             )

    line2 = encode_envelope({fail_claims, fail_sig})

    assert {:ok, {after_claims, after_sig}} =
             Events.message_received(
               @human_seed,
               1_754_512_345_702.0,
               "message:discord:dddddddddddddddddddd:13",
               "channel:discord:dddddddddddddddddddd",
               "session:discord:dddddddddddddddddddd",
               "hello never reached"
             )

    line3 = encode_envelope({after_claims, after_sig})

    text = Enum.join([line1, line2, line3], "\n")

    assert {:error, {:import_failed, 2, :persist_failed}} = Federation.import(text)

    # the partial report is visible: line1's refusal survives, the failed
    # line (2) is counted nowhere, line3 was never reached
    assert Federation.import_report() == %{imported: 0, refused: [1], skipped: 0}

    set = DurableStore.set()
    refute DeltaSet.member?(set, Delta.id_hex(fail_claims))
    refute DeltaSet.member?(set, Delta.id_hex(after_claims))
  end

  # ----------------------------------------------------------------- AC10

  test "AC10: classification parity — import/1 and a boot replay classify identical bytes the same way" do
    assert {:ok, valid_signed} =
             Events.message_received(
               @human_seed,
               1_754_512_345_710.0,
               "message:discord:eeeeeeeeeeeeeeeeeeee:14",
               "channel:discord:eeeeeeeeeeeeeeeeeeee",
               "session:discord:eeeeeeeeeeeeeeeeeeee",
               "hello parity valid"
             )

    assert {:ok, {tamper_claims, tamper_sig}} =
             Events.message_received(
               @human_seed,
               1_754_512_345_711.0,
               "message:discord:ffffffffffffffffffff:15",
               "channel:discord:ffffffffffffffffffff",
               "session:discord:ffffffffffffffffffff",
               "hello parity tampered"
             )

    assert {:ok, torn_signed} =
             Events.message_received(
               @human_seed,
               1_754_512_345_712.0,
               "message:discord:gggggggggggggggggggg:16",
               "channel:discord:gggggggggggggggggggg",
               "session:discord:gggggggggggggggggggg",
               "hello parity torn"
             )

    valid_line = encode_envelope(valid_signed)

    tampered_line =
      Wire.envelope({tamper_claims, tamper_sig}) |> tamper_sig_field() |> encode_wire()

    torn_line = String.slice(encode_envelope(torn_signed), 0, 20)

    # CRLF on line 1 (parity with Kyber.Log.strip_eol), plain LF on line 2,
    # a torn FINAL line with no trailing newline at all
    raw = valid_line <> "\r\n" <> tampered_line <> "\n" <> torn_line

    replay_dir = fresh_dir(System.tmp_dir!(), "replay")
    replay_path = Path.join(replay_dir, "store.jsonl")
    File.mkdir_p!(replay_dir)
    File.write!(replay_path, raw)
    boot_on(replay_path)

    replay_report = DurableStore.replay_report()
    replay_set = DurableStore.set()

    import_dir = fresh_dir(System.tmp_dir!(), "import")
    boot_on(Path.join(import_dir, "store.jsonl"))

    assert {:ok, import_report} = Federation.import(raw)
    import_set = DurableStore.set()

    assert import_set == replay_set

    assert Enum.sort(replay_report.refused ++ replay_report.torn) ==
             Enum.sort(import_report.refused)

    File.rm_rf(replay_dir)
    File.rm_rf(import_dir)
  end
end
