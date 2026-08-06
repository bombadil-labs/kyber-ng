defmodule Kyber.DurableStoreTest do
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, DurableStore, Events, Log, Store, TestWire}
  alias Rhizomatic.{Delta, Ed25519, Signer}

  @human_seed String.duplicate("cd", 32)
  @agent_seed String.duplicate("ab", 32)
  @ts 1_754_512_345_678

  # keeps runtime artifacts out of the repo tree (never `ExUnit`'s built-in
  # `:tmp_dir` tag, which resolves under the project root)
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kyber-durable-store-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, tmp_dir: dir}
  end

  defp message(message_id) do
    assert {:ok, signed} =
             Events.message_received(
               @human_seed,
               @ts,
               message_id,
               "channel:discord:111111111111111111",
               "session:discord:111111111111111111",
               "hello " <> message_id
             )

    signed
  end

  defp wire(message_id \\ "message:discord:111111111111111111:1") do
    TestWire.envelope(message(message_id))
  end

  defp tamper_sig(wire) do
    <<c::binary-1, rest::binary>> = wire["sig"]
    flipped = if c == "0", do: "1", else: "0"
    %{wire | "sig" => flipped <> rest}
  end

  defp start_store(path) do
    start_supervised!({DurableStore, path})
  end

  # ------------------------------------------------------------------ AC2

  test "AC2: a delta survives a restart and its signature re-verifies", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)

    {claims, sig_hex} = message("message:discord:111111111111111111:1")
    id = Delta.id_hex(claims)
    assert :ok = DurableStore.append(TestWire.envelope({claims, sig_hex}))
    assert DeltaSet.member?(DurableStore.set(), id)

    stop_supervised!(DurableStore)
    start_store(path)

    set = DurableStore.set()
    assert DeltaSet.member?(set, id)
    assert Map.fetch!(set, id) == {claims, sig_hex}
    assert Signer.verify(claims, sig_hex, id)
  end

  # ------------------------------------------------------------------ AC3

  test "AC3: a torn FINAL line is tolerated and reported", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")
    full = JSON.encode!(wire("message:discord:111111111111111111:1"))
    fragment = String.slice(full, 0, 20)

    File.write!(path, full <> "\n" <> fragment)

    start_store(path)

    assert DeltaSet.size(DurableStore.set()) == 1
    assert DurableStore.replay_report() == %{refused: [], torn: [2]}
  end

  # ------------------------------------------------------------------ AC4

  test "AC4: a tampered line mid-log is refused and reported", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")

    w1 = wire("message:discord:111111111111111111:1")
    w2 = wire("message:discord:222222222222222222:2") |> tamper_sig()
    w3 = wire("message:discord:333333333333333333:3")

    File.write!(
      path,
      Enum.map_join([w1, w2, w3], "\n", &JSON.encode!/1) <> "\n"
    )

    start_store(path)

    set = DurableStore.set()
    assert DeltaSet.size(set) == 2
    refute DeltaSet.member?(set, w2["id"])
    assert DurableStore.replay_report() == %{refused: [2], torn: []}
  end

  # ------------------------------------------------------------------ AC5

  test "AC5: replay is order-independent — shuffled lines converge to the same set", %{
    tmp_dir: tmp_dir
  } do
    wires =
      for n <- 1..4 do
        id = String.duplicate(Integer.to_string(n), 18)
        wire("message:discord:#{id}:#{n}")
      end

    path_a = Path.join(tmp_dir, "a.jsonl")
    path_b = Path.join(tmp_dir, "b.jsonl")

    # a fixed, deterministic permutation (never `Enum.shuffle/1` — this repo
    # values determinism over cleverness in tests)
    shuffled = Enum.map([3, 1, 4, 2], &Enum.at(wires, &1 - 1))

    File.write!(path_a, Enum.map_join(wires, "\n", &JSON.encode!/1) <> "\n")
    File.write!(path_b, Enum.map_join(shuffled, "\n", &JSON.encode!/1) <> "\n")

    start_store(path_a)
    set_a = DurableStore.set()
    stop_supervised!(DurableStore)

    start_store(path_b)
    set_b = DurableStore.set()

    assert DeltaSet.size(set_a) == 4
    assert set_a == set_b
  end

  # ------------------------------------------------------------------ AC6

  test "AC6: a door-rejected delta writes nothing — set and file unchanged", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)

    bad = wire() |> tamper_sig()
    assert {:error, :bad_signature} = DurableStore.append(bad)

    assert DeltaSet.size(DurableStore.set()) == 0
    refute File.exists?(path)
  end

  test "AC6: an unsigned delta is refused by the door and writes nothing", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)

    unsigned = wire() |> Map.delete("sig")
    assert {:error, :unsigned} = DurableStore.append(unsigned)

    assert DeltaSet.size(DurableStore.set()) == 0
    refute File.exists?(path)
  end

  # ------------------------------------------------------------------ AC8

  test "AC8: a mid-log torn line is classified without disturbing the valid deltas around it",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")

    w1 = wire("message:discord:111111111111111111:1")
    w3 = wire("message:discord:333333333333333333:3")
    fragment = String.slice(JSON.encode!(w1), 0, 15)

    File.write!(
      path,
      JSON.encode!(w1) <> "\n" <> fragment <> "\n" <> JSON.encode!(w3) <> "\n"
    )

    start_store(path)

    set = DurableStore.set()
    assert DeltaSet.size(set) == 2
    assert DeltaSet.member?(set, w1["id"])
    assert DeltaSet.member?(set, w3["id"])
    assert DurableStore.replay_report() == %{refused: [], torn: [2]}
  end

  # ------------------------------------------------------------------ AC9

  test "AC9: write-ahead — a persist failure leaves the set and file unchanged", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)

    w1 = wire("message:discord:111111111111111111:1")
    assert :ok = DurableStore.append(w1)

    # close the log device behind the store's back, forcing the next
    # persist attempt to fail
    state = :sys.get_state(DurableStore)
    assert :ok = File.close(state.io)

    before_set = DurableStore.set()
    before_file = File.read!(path)

    w2 = wire("message:discord:222222222222222222:2")
    assert {:error, :persist_failed} = DurableStore.append(w2)

    assert DurableStore.set() == before_set
    assert File.read!(path) == before_file

    # P5: recovery — after a persist failure the store reopens the device and
    # keeps working (this exercises the reopen path and the fd lifecycle)
    w3 = wire("message:discord\n333333333333333333: 3")
    assert :ok = DurableStore.append(w3)
    assert DeltaSet.member?(DurableStore.set(), w3["id"])
    assert File.read!(path) == before_file <> JSON.encode!(w3) <> "\n"
  end

  # ----------------------------------------------------------------- AC10

  test "AC10: a stored line decodes to a term-identical envelope and re-admits", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "log.jsonl")
    {:ok, io} = Log.open(path)
    envelope = wire()
    assert :ok = Log.append(io, envelope)
    File.close(io)

    [line] = Log.stream(path) |> Enum.to_list()
    assert {:ok, decoded} = JSON.decode(line)
    assert decoded == envelope
    assert {:ok, _set} = Store.admit(decoded, DeltaSet.new())
  end

  # ----------------------------------------------------------------- AC11

  test "AC11: first boot on a nonexistent path is empty; the log is created lazily", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "log.jsonl")
    refute File.exists?(path)

    start_store(path)
    assert DeltaSet.size(DurableStore.set()) == 0
    refute File.exists?(path)

    assert :ok = DurableStore.append(wire())
    assert File.exists?(path)
  end

  # ----------------------------------------------------------------- AC12

  test "AC12: replay_report/0 is the pinned observable, empty on a clean boot", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)
    assert DurableStore.replay_report() == %{refused: [], torn: []}
  end

  # -------------------------------------------------------- misc / duplicates

  test "duplicates across a restart are no-ops (union)", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)

    w = wire()
    assert :ok = DurableStore.append(w)
    assert :ok = DurableStore.append(w)
    assert DeltaSet.size(DurableStore.set()) == 1

    stop_supervised!(DurableStore)
    start_store(path)
    assert DeltaSet.size(DurableStore.set()) == 1
  end

  test "an empty/whitespace-only line is skipped silently and unreported", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "log.jsonl")
    w1 = wire("message:discord:111111111111111111:1")

    File.write!(path, JSON.encode!(w1) <> "\n" <> "   \n" <> "\n")

    start_store(path)

    assert DeltaSet.size(DurableStore.set()) == 1
    assert DurableStore.replay_report() == %{refused: [], torn: []}
  end

  test "a syntactically valid JSON line that is not the envelope shape is refused", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "log.jsonl")
    File.write!(path, JSON.encode!([1, 2, 3]) <> "\n")

    start_store(path)

    assert DeltaSet.size(DurableStore.set()) == 0
    assert DurableStore.replay_report() == %{refused: [1], torn: []}
  end

  test "AC5: the door rejects a signature by the wrong key, through DurableStore", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "log.jsonl")
    start_store(path)

    {claims, _sig} = message("message:discord:111111111111111111:1")
    wrong_seed = Base.decode16!(@agent_seed, case: :mixed)
    wrong_sig = Base.encode16(Ed25519.sign(Delta.id_bytes(claims), wrong_seed), case: :lower)

    assert {:error, :bad_signature} =
             DurableStore.append(TestWire.envelope({claims, wrong_sig}))

    assert DeltaSet.size(DurableStore.set()) == 0
  end
end
