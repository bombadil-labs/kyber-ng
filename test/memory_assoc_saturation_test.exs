defmodule Kyber.Agent.MemoryAssocSaturationTest do
  @moduledoc """
  T13 AC2 — groove is saturation: a long session (3×8 exchanges) is driven
  through the context builder with the associative retriever; the prefetch
  heads ride the emitted request's memoryPointers, and the walked-edge
  count is FLAT after saturation (`edges_walked(turn 9) == edges_walked(turn
  24)`) because seeds derive only from the bounded window.

  The driven store accumulates the session's `message.received` turns; the
  emitted requests are NOT folded back in — a store where every request's
  memoryPointers citations accumulate on the cited canons grows `{:cite, _}`
  features per turn, which is the recorded groove caveat (see the T13
  report), not this test's subject.
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Schema, Store, Wire}
  alias Kyber.Agent.ContextBuilder
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.Assoc.Saturation
  alias Kyber.Agent.Memory.Retriever

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)
  @session "sess:groove"

  defp admit!(set, signed) do
    wire = Wire.envelope(signed)
    assert {:ok, set} = Store.admit(wire, set)
    {set, wire["id"]}
  end

  defp remember!(set, ts, entity_id, content, sources) do
    {:ok, signed} = AgentEvents.memory_entity(@agent_seed, ts, entity_id, content, sources)
    admit!(set, signed)
  end

  test "AC2: prefetch heads ride the request and edges_walked(turn 9) == edges_walked(turn 24)" do
    set = DeltaSet.new()

    {:ok, signed} =
      Events.message_received(@human_seed, 1.0, "msg:0", "chan:1", @session, "hi")

    {set, recv0} = admit!(set, signed)

    {set, _} = remember!(set, 2.0, "mem:alpha", "relay deploy pinned", [recv0])
    {set, _} = remember!(set, 3.0, "mem:beta", "relay deploy checklist", [recv0])
    {set, _} = remember!(set, 4.0, "mem:gamma", "relay archive notes", [recv0])
    # out-of-session, sourceless: reachable only through digest edges — the
    # walk's divergent channel, present every saturated turn
    {set, _} = remember!(set, 5.0, "mem:omega", "deploy status archive", [])

    omega_head = Memory.canon(set, "mem:omega").head

    {_set, edges, last} =
      Enum.reduce(1..24, {set, %{}, nil}, fn turn, {set, edges, _last} ->
        # "#{turn}" tokenizes below the 4-byte floor: prompts differ as
        # strings, digest-identical — the window's resonance is stable
        prompt = "relay deploy status check #{turn}"

        {:ok, signed} =
          Events.message_received(
            @human_seed,
            10.0 + turn,
            "msg:#{turn}",
            "chan:1",
            @session,
            prompt
          )

        wire = Wire.envelope(signed)
        assert {:ok, set} = Store.admit(wire, set)
        assert {:ok, received} = Store.verify(wire)

        handler =
          ContextBuilder.handler(
            seed: @agent_seed,
            store: fn -> set end,
            memory: {Retriever, %{store: fn -> set end, assoc: true}}
          )

        assert [request] = handler.([%{id: received.id, claims: received.claims}])

        prefetch = Saturation.prefetch(set, @session, prompt)
        {set, Map.put(edges, turn, prefetch.edges_walked), {request, prefetch}}
      end)

    # the pre-fetched association set is present in the NEXT request
    {request, prefetch} = last
    assert {:ok, verified} = Store.verify(request)

    pointer_ids =
      for {:delta, id, _ctx} <- Schema.resolve(verified.claims).memoryPointers, do: id

    for head <- prefetch.seeds ++ prefetch.resonant ++ prefetch.divergent do
      assert head in pointer_ids
    end

    assert prefetch.divergent == [omega_head]
    assert length(prefetch.seeds) == 3

    # the groove: per-turn recall cost is flat after saturation
    assert edges[9] == edges[24]
    assert edges[9] > 0
  end
end
