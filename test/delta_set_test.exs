defmodule Kyber.DeltaSetTest do
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678.0

  # 3-delta fixture: three distinct message_received deltas
  defp fixture do
    [
      "message:discord:111111111111111111:1",
      "message:discord:222222222222222222:2",
      "message:discord:333333333333333333:3"
    ]
    |> Enum.map(fn message_id ->
      channel = "channel:discord:111111111111111111"
      session = "session:discord:111111111111111111"

      assert {:ok, signed} =
               Events.message_received(
                 @human_seed,
                 @ts,
                 message_id,
                 channel,
                 session,
                 "hello " <> message_id
               )

      signed
    end)
  end

  defp element_id({claims, _sig}), do: Delta.id_hex(claims)

  defp set_of(elements) do
    Map.new(elements, fn {claims, _sig} = element -> {Delta.id_hex(claims), element} end)
  end

  test "new/0 is empty" do
    assert DeltaSet.size(DeltaSet.new()) == 0
  end

  test "member?/2 looks elements up by id hex" do
    [d1 | _rest] = fixture()
    set = set_of([d1])

    assert DeltaSet.member?(set, element_id(d1))
    refute DeltaSet.member?(set, "1e20" <> String.duplicate("ff", 32))
  end

  describe "AC4: merge is commutative + idempotent on the 3-delta fixture" do
    test "merge(a, b) == merge(b, a) and both orders converge" do
      [d1, d2, d3] = fixture()
      a = set_of([d1, d2])
      b = set_of([d2, d3])

      assert DeltaSet.merge(a, b) == DeltaSet.merge(b, a)
      assert DeltaSet.size(DeltaSet.merge(a, b)) == 3
      ab = DeltaSet.merge(a, b)
      ba = DeltaSet.merge(b, a)

      for id <- [element_id(d1), element_id(d2), element_id(d3)] do
        assert DeltaSet.member?(ab, id)
        assert DeltaSet.member?(ba, id)
      end
    end

    test "merge(s, s) == s" do
      [d1, d2, d3] = fixture()
      s = set_of([d1, d2, d3])
      assert DeltaSet.merge(s, s) == s
      assert DeltaSet.size(DeltaSet.merge(s, s)) == 3
    end

    test "union keeps distinct deltas and collapses duplicates by content id" do
      [d1, d2, d3] = fixture()
      merged = DeltaSet.merge(set_of([d1, d2]), set_of([d2, d3]))
      assert DeltaSet.size(merged) == 3

      assert Enum.all?([d1, d2, d3], fn {claims, _sig} = el ->
               DeltaSet.member?(merged, Delta.id_hex(claims)) and
                 Map.fetch!(merged, Delta.id_hex(claims)) == el
             end)
    end
  end
end
