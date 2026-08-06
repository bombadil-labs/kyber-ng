defmodule Kyber.EventsTest do
  use ExUnit.Case, async: true

  alias Kyber.{Events, Keys, TestWire}
  alias Rhizomatic.{Delta, Hash, Profile, Signer}

  @agent_seed String.duplicate("ab", 32)
  @human_seed String.duplicate("cd", 32)

  @ts 1_754_512_345_678
  @delta_ref "1e20" <> String.duplicate("00", 32)

  # canonical fixture per spec/01-events.md §2
  @message_id "message:discord:123456789012345678:987654321098765432"
  @channel_id "channel:discord:123456789012345678"
  @session_id "session:discord:123456789012345678"
  @content "hello Veles"

  defp human_id(seed \\ @human_seed) do
    "human:" <> String.trim_leading(Keys.author_for_seed(seed), "ed25519:")
  end

  defp assert_pointers(claims, expected) do
    assert MapSet.equal?(MapSet.new(claims.pointers), MapSet.new(expected))
    assert length(claims.pointers) == length(expected)
    # MapSet + length cannot see a duplicated role with distinct targets (an
    # extra pointer AC8 forbids) — assert role uniqueness explicitly
    roles = Enum.map(claims.pointers, & &1.role)
    assert MapSet.size(MapSet.new(roles)) == length(roles)
  end

  describe "AC2 + AC3: id recomputes, signature verifies, right author for every emitted delta" do
    test "message_received is signed by the human's key" do
      assert {:ok, {claims, sig_hex}} =
               Events.message_received(
                 @human_seed,
                 @ts,
                 @message_id,
                 @channel_id,
                 @session_id,
                 @content
               )

      assert Delta.id_hex(claims) == Hash.id_hex(Delta.canonical_bytes(claims))
      assert Signer.verify(claims, sig_hex, Delta.id_hex(claims))
      assert claims.author == Keys.author_for_seed(@human_seed)
    end

    test "prompt_annotated is signed by the agent's key" do
      assert {:ok, {claims, sig_hex}} =
               Events.prompt_annotated(
                 @agent_seed,
                 @ts,
                 @delta_ref,
                 "salience: L0 tags [kyber, rhizome]; L1 summary"
               )

      assert Delta.id_hex(claims) == Hash.id_hex(Delta.canonical_bytes(claims))
      assert Signer.verify(claims, sig_hex, Delta.id_hex(claims))
      assert claims.author == Keys.author_for_seed(@agent_seed)
    end

    test "llm_response is signed by the agent's key" do
      assert {:ok, {claims, sig_hex}} =
               Events.llm_response(@agent_seed, @ts, @delta_ref, "…the model's reply…")

      assert Delta.id_hex(claims) == Hash.id_hex(Delta.canonical_bytes(claims))
      assert Signer.verify(claims, sig_hex, Delta.id_hex(claims))
      assert claims.author == Keys.author_for_seed(@agent_seed)
    end

    test "message_sent is signed by the agent's key" do
      out_message_id = "message:discord:123456789012345678:out-42"

      assert {:ok, {claims, sig_hex}} =
               Events.message_sent(
                 @agent_seed,
                 @ts,
                 @delta_ref,
                 out_message_id,
                 @channel_id,
                 "…the delivered text…"
               )

      assert Delta.id_hex(claims) == Hash.id_hex(Delta.canonical_bytes(claims))
      assert Signer.verify(claims, sig_hex, Delta.id_hex(claims))
      assert claims.author == Keys.author_for_seed(@agent_seed)
    end

    test "tool_exec is signed by the agent's key" do
      assert {:ok, {claims, sig_hex}} =
               Events.tool_exec(
                 @agent_seed,
                 @ts,
                 @delta_ref,
                 "tool:exec",
                 "ls -la /tmp",
                 "total 8\ndrwxrwxr-x"
               )

      assert Delta.id_hex(claims) == Hash.id_hex(Delta.canonical_bytes(claims))
      assert Signer.verify(claims, sig_hex, Delta.id_hex(claims))
      assert claims.author == Keys.author_for_seed(@agent_seed)
    end
  end

  describe "AC8: pointer-set equality against the spec/01-events.md §2 templates" do
    test "message_received emits exactly the §2.1 pointers" do
      assert {:ok, {claims, _sig}} =
               Events.message_received(
                 @human_seed,
                 @ts,
                 @message_id,
                 @channel_id,
                 @session_id,
                 @content
               )

      assert_pointers(claims, [
        %{role: "received", target: {:entity, @message_id, "incoming"}},
        %{role: "at", target: {:entity, @channel_id, "messages"}},
        %{role: "by", target: {:entity, human_id(), "sent"}},
        %{role: "content", target: {:string, @content}},
        %{role: "session", target: {:entity, @session_id, "messages"}}
      ])
    end

    test "prompt_annotated emits exactly the §2.2 pointers" do
      notes = "salience: L0 tags [kyber, rhizome]; L1 summary"

      assert {:ok, {claims, _sig}} = Events.prompt_annotated(@agent_seed, @ts, @delta_ref, notes)

      assert_pointers(claims, [
        %{role: "annotates", target: {:delta, @delta_ref, "annotated"}},
        %{role: "notes", target: {:string, notes}}
      ])
    end

    test "llm_response emits exactly the §2.3 pointers" do
      content = "…the model's reply…"

      assert {:ok, {claims, _sig}} = Events.llm_response(@agent_seed, @ts, @delta_ref, content)

      assert_pointers(claims, [
        %{role: "responds", target: {:delta, @delta_ref, "answer"}},
        %{role: "content", target: {:string, content}},
        %{role: "usage", target: {:entity, "agent:kyber", "tokens"}}
      ])
    end

    test "message_sent emits exactly the §2.4 pointers" do
      out_message_id = "message:discord:123456789012345678:out-42"
      content = "…the delivered text…"

      assert {:ok, {claims, _sig}} =
               Events.message_sent(
                 @agent_seed,
                 @ts,
                 @delta_ref,
                 out_message_id,
                 @channel_id,
                 content
               )

      assert_pointers(claims, [
        %{role: "sent", target: {:entity, out_message_id, "outgoing"}},
        %{role: "via", target: {:entity, @channel_id, "sent"}},
        %{role: "content", target: {:string, content}},
        %{role: "caused_by", target: {:delta, @delta_ref, nil}}
      ])
    end

    test "tool_exec emits exactly the §2.5 pointers" do
      args = "ls -la /tmp"
      result = "total 8\ndrwxrwxr-x"

      assert {:ok, {claims, _sig}} =
               Events.tool_exec(@agent_seed, @ts, @delta_ref, "tool:exec", args, result)

      assert_pointers(claims, [
        %{role: "tool", target: {:entity, "tool:exec", "invocations"}},
        %{role: "args", target: {:string, args}},
        %{role: "result", target: {:string, result}},
        %{role: "during", target: {:delta, @delta_ref, "tool_use"}}
      ])
    end
  end

  describe "AC6: wire claims round-trip through Profile.parse_claims/1 byte-identically" do
    test "a signed message_received re-serializes to identical canonical bytes" do
      assert {:ok, signed = {claims, _sig}} =
               Events.message_received(
                 @human_seed,
                 @ts,
                 @message_id,
                 @channel_id,
                 @session_id,
                 @content
               )

      wire = TestWire.envelope(signed)

      # the loam-compatibility proof must exercise the real JSON-text path —
      # float formatting and escaping included — not just the in-memory map
      # shape (P5 finding 7)
      wire = wire |> JSON.encode!() |> JSON.decode!()

      assert {:ok, reparsed} = Profile.parse_claims(wire["claims"])
      assert Delta.canonical_bytes(reparsed) == Delta.canonical_bytes(claims)
      assert Delta.id_hex(reparsed) == Delta.id_hex(claims)
    end
  end

  describe "D14: builders convert integer timestamps to floats, never coerce inside the witness" do
    test "an integer ts becomes a float ms timestamp" do
      assert {:ok, {claims, _sig}} =
               Events.message_received(
                 @human_seed,
                 1_754_512_345_678,
                 @message_id,
                 @channel_id,
                 @session_id,
                 @content
               )

      assert is_float(claims.timestamp)
      assert claims.timestamp == 1_754_512_345_678.0
    end

    test "a float ts passes through unchanged" do
      assert {:ok, {claims, _sig}} =
               Events.message_received(
                 @human_seed,
                 1_754_512_345_678.0,
                 @message_id,
                 @channel_id,
                 @session_id,
                 @content
               )

      assert claims.timestamp == 1_754_512_345_678.0
    end

    test "a non-numeric ts is rejected, never repaired" do
      assert {:error, :timestamp_not_a_number} =
               Events.message_received(
                 @human_seed,
                 "now",
                 @message_id,
                 @channel_id,
                 @session_id,
                 @content
               )
    end

    test "an empty entity id is rejected by the claims boundary" do
      assert {:error, _} =
               Events.message_received(@human_seed, @ts, "", @channel_id, @session_id, @content)
    end
  end
end
