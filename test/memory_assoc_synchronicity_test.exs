defmodule Kyber.Agent.MemoryAssocSynchronicityTest do
  @moduledoc """
  T13 AC3 — synchronicity is a graph property (fixture pinned verbatim):
  sessA holds entity x "aurora tide fjord" (source deltas in BOTH sessions,
  distinct deltas — the shared entity) and entity y "fjord kayak gear"
  (sessA only); sessB holds entity z "aurora tide report" (sessB only). A
  sessA query surfaces z in the DIVERGENT channel — surprising
  shared-feature overlap, no direct link — deterministically, capped, with
  precision recall unchanged.
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Store, Wire}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.Retriever

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)

  defp admit!(set, signed) do
    wire = Wire.envelope(signed)
    assert {:ok, set} = Store.admit(wire, set)
    {set, wire["id"]}
  end

  defp received!(set, ts, message_id, session_id, content) do
    {:ok, signed} =
      Events.message_received(@human_seed, ts, message_id, "chan:1", session_id, content)

    admit!(set, signed)
  end

  defp remember!(set, ts, entity_id, content, sources) do
    {:ok, signed} = AgentEvents.memory_entity(@agent_seed, ts, entity_id, content, sources)
    admit!(set, signed)
  end

  test "AC3: the cross-session entity rides the divergent channel — no direct link, capped, precision unchanged" do
    set = DeltaSet.new()
    {set, recv_a1} = received!(set, 1.0, "msg:a1", "sessA", "hi")
    {set, recv_b1} = received!(set, 2.0, "msg:b1", "sessB", "yo")
    {set, recv_a2} = received!(set, 3.0, "msg:a2", "sessA", "ok")
    {set, recv_b2} = received!(set, 4.0, "msg:b2", "sessB", "hm")

    {set, _} = remember!(set, 5.0, "ent:x", "aurora tide fjord", [recv_a1, recv_b1])
    {set, _} = remember!(set, 6.0, "ent:y", "fjord kayak gear", [recv_a2])
    {set, _} = remember!(set, 7.0, "ent:z", "aurora tide report", [recv_b2])

    query = %{session_id: "sessA", prompt: "the aurora tide fjord crossing"}

    assert {:ok, %{memory_ids: memory_ids, associations: associations}} =
             Retriever.retrieve(query, %{store: set, assoc: true})

    z_head = Memory.canon(set, "ent:z").head

    assert z_head in associations.divergent
    refute z_head in associations.resonant
    assert length(associations.divergent) <= 2

    # precision recall unchanged: memory_ids == the precision-mode result
    assert Retriever.retrieve(query, %{store: set}) == {:ok, memory_ids}

    # deterministic: two runs byte-equal
    assert Retriever.retrieve(query, %{store: set, assoc: true}) ==
             Retriever.retrieve(query, %{store: set, assoc: true})
  end
end
