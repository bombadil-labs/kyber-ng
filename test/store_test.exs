defmodule Kyber.StoreTest do
  use ExUnit.Case, async: false

  alias Kyber.{DeltaSet, Events, Store, TestWire}
  alias Rhizomatic.{Delta, Ed25519}

  @agent_seed String.duplicate("ab", 32)
  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678

  setup do
    start_supervised!(Store)
    :ok
  end

  defp human_message do
    Events.message_received(
      @human_seed,
      @ts,
      "message:discord:123456789012345678:987654321098765432",
      "channel:discord:123456789012345678",
      "session:discord:123456789012345678",
      "hello Veles"
    )
  end

  test "the door verifies and merges a valid signed delta" do
    assert {:ok, signed = {claims, sig_hex}} = human_message()
    assert :ok = Store.append(TestWire.envelope(signed))

    set = Store.set()
    id = Delta.id_hex(claims)
    assert DeltaSet.member?(set, id)
    assert DeltaSet.size(set) == 1
    assert Map.fetch!(set, id) == {claims, sig_hex}
  end

  test "duplicates are no-ops (union through the door)" do
    assert {:ok, signed} = human_message()
    wire = TestWire.envelope(signed)

    assert :ok = Store.append(wire)
    assert :ok = Store.append(wire)
    assert DeltaSet.size(Store.set()) == 1
  end

  test "distinct signed deltas accumulate" do
    assert {:ok, mr = {mr_claims, _}} = human_message()

    assert {:ok, ms} =
             Events.message_sent(
               @agent_seed,
               @ts,
               Delta.id_hex(mr_claims),
               "message:discord:123456789012345678:out-42",
               "channel:discord:123456789012345678",
               "delivered"
             )

    assert :ok = Store.append(TestWire.envelope(mr))
    assert :ok = Store.append(TestWire.envelope(ms))
    assert DeltaSet.size(Store.set()) == 2
  end

  test "AC5: the door rejects a tampered id" do
    assert {:ok, signed} = human_message()
    wire = TestWire.envelope(signed)

    id = wire["id"]
    tampered = String.slice(id, 0..-2//1) <> if(String.ends_with?(id, "0"), do: "1", else: "0")
    wire = Map.put(wire, "id", tampered)

    assert {:error, :id_mismatch} = Store.append(wire)
    assert DeltaSet.size(Store.set()) == 0
  end

  test "AC5: the door rejects a signature by the wrong key" do
    assert {:ok, {claims, _sig}} = human_message()

    # signature over the id bytes by the AGENT seed, while the claims name the HUMAN key
    wrong_seed = Base.decode16!(@agent_seed, case: :mixed)
    wrong_sig = Base.encode16(Ed25519.sign(Delta.id_bytes(claims), wrong_seed), case: :lower)

    assert {:error, :bad_signature} = Store.append(TestWire.envelope({claims, wrong_sig}))
    assert DeltaSet.size(Store.set()) == 0
  end

  test "AC5: the door rejects an unsigned delta (D1)" do
    assert {:ok, signed} = human_message()
    wire = TestWire.envelope(signed) |> Map.delete("sig")

    assert {:error, :unsigned} = Store.append(wire)
    assert DeltaSet.size(Store.set()) == 0
  end

  test "P5: the door rejects an envelope with unknown keys (closedness, like the witness profile)" do
    assert {:ok, signed} = human_message()
    wire = TestWire.envelope(signed) |> Map.put("nonce", "x")

    assert {:error, {:unknown_key, :envelope, "nonce"}} = Store.append(wire)
    assert DeltaSet.size(Store.set()) == 0
  end
end

defmodule Kyber.StoreNotStartedTest do
  use ExUnit.Case, async: false

  alias Kyber.Store

  test "append/1 and set/0 return {:error, :store_not_running} before the door is started" do
    assert {:error, :store_not_running} =
             Store.append(%{"id" => "x", "claims" => %{}, "sig" => "y"})

    assert {:error, :store_not_running} = Store.set()
  end
end
