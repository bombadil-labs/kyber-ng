defmodule Kyber.WireTest do
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Store, TestWire, Wire}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @agent_seed String.duplicate("ab", 32)
  @ts 1_754_512_345_678

  defp signed_event(event) do
    assert {:ok, signed} = event
    signed
  end

  defp message_received(message_id) do
    signed_event(
      Events.message_received(
        @human_seed,
        @ts,
        message_id,
        "channel:discord:111111111111111111",
        "session:discord:111111111111111111",
        "hello " <> message_id
      )
    )
  end

  describe "AC2: wire parity + round-trip" do
    test "envelope/1 and claims_json/1 are byte-identical to TestWire on a signed message_received event" do
      {claims, sig_hex} = message_received("message:discord:111111111111111111:1")

      assert Wire.envelope({claims, sig_hex}) == TestWire.envelope({claims, sig_hex})
      assert Wire.claims_json(claims) == TestWire.claims_json(claims)

      assert JSON.encode!(Wire.envelope({claims, sig_hex})) ==
               JSON.encode!(TestWire.envelope({claims, sig_hex}))

      assert JSON.encode!(Wire.claims_json(claims)) == JSON.encode!(TestWire.claims_json(claims))
    end

    test "parity holds on a second event shape (message_sent: delta pointers, nil context)" do
      assert {:ok, {mr_claims, _}} =
               Events.message_received(
                 @human_seed,
                 @ts,
                 "m:1",
                 "channel:discord:111111111111111111",
                 "session:discord:111111111111111111",
                 "hello parity"
               )

      {claims, sig_hex} =
        signed_event(
          Events.message_sent(
            @agent_seed,
            @ts,
            Delta.id_hex(mr_claims),
            "message:discord:111111111111111111:out-42",
            "channel:discord:111111111111111111",
            "delivered"
          )
        )

      assert Wire.envelope({claims, sig_hex}) == TestWire.envelope({claims, sig_hex})

      assert JSON.encode!(Wire.envelope({claims, sig_hex})) ==
               JSON.encode!(TestWire.envelope({claims, sig_hex}))
    end

    test "encode -> decode is term-identical" do
      wire = Wire.envelope(message_received("message:discord:222222222222222222:2"))

      assert {:ok, json} = Wire.encode(wire)
      assert {:ok, decoded} = Wire.decode(json)
      assert decoded == wire
    end

    test "the envelope re-admits through the door" do
      wire = Wire.envelope(message_received("message:discord:333333333333333333:3"))
      assert {:ok, _set} = Store.admit(wire, DeltaSet.new())
    end
  end

  describe "AC3: wire error symmetry" do
    test "encode refuses non-map input" do
      assert {:error, {:encode, :not_a_map}} = Wire.encode("not a map")
      assert {:error, {:encode, :not_a_map}} = Wire.encode([1, 2, 3])
      assert {:error, {:encode, :not_a_map}} = Wire.encode(42)
    end

    test "encode refuses values with no JSON.Encoder implementation" do
      assert {:error, {:encode, _}} = Wire.encode(%{"a" => {1, 2}})
      assert {:error, {:encode, _}} = Wire.encode(%{"a" => self()})
      assert {:error, {:encode, _}} = Wire.encode(%{"a" => make_ref()})
    end

    test "encode refuses non-string keys at ANY depth (stdlib would silently stringify)" do
      assert {:error, {:encode, :non_string_key}} = Wire.encode(%{1 => "a", "b" => 2})
      assert {:error, {:encode, :non_string_key}} = Wire.encode(%{atom_key: "a"})
      assert {:error, {:encode, :non_string_key}} = Wire.encode(%{"a" => %{nested: 1}})
      assert {:error, {:encode, :non_string_key}} = Wire.encode(%{"a" => %{"b" => %{1 => "x"}}})
      assert {:error, {:encode, :non_string_key}} = Wire.encode(%{"a" => [%{deep: 1}]})
    end

    test "a nested atom-keyed map inside claims is refused (AC3)" do
      wire =
        Wire.envelope(message_received("message:discord:444444444444444444:4"))
        |> Map.put(
          "claims",
          %{
            "timestamp" => @ts,
            "author" => "ed25519:abc",
            "pointers" => [%{"role" => "x", "target" => %{bad: 1}}]
          }
        )

      assert {:error, {:encode, :non_string_key}} = Wire.encode(wire)
    end

    test "decode refuses malformed JSON" do
      assert {:error, {:decode, _}} = Wire.decode("not json")
      assert {:error, {:decode, _}} = Wire.decode("{\"a\": ")
    end

    test "decode refuses VALID JSON that is not a map (decode symmetry)" do
      assert {:error, {:decode, :not_a_map}} = Wire.decode("[]")
      assert {:error, {:decode, :not_a_map}} = Wire.decode("42")
      assert {:error, {:decode, :not_a_map}} = Wire.decode("\"str\"")
      assert {:error, {:decode, :not_a_map}} = Wire.decode("null")
    end
  end
end
