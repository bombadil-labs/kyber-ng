defmodule Kyber.Agent.MemoryAssocRetrieverTest do
  @moduledoc """
  T13 AC10 — the associative retriever and the T11c retriever are
  A/B-swappable behind the same seam: a three-way check (Stub vs
  `%{store: s}` vs `%{store: s, assoc: true}`) on a store WITH shareable
  features (a no-feature fixture is vacuous). Precision output is byte-equal
  across all legs; the assoc leg's divergent channel is bounded (0..2), and
  the associative tail never truncates precision.
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, MemoryPort}
  alias Kyber.Agent.Events, as: AgentEvents
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

  # a store WITH shareable features: cross-session digest overlap, shared
  # sources, distinct sessions (the AC3 shape)
  defp store! do
    set = DeltaSet.new()
    {set, recv_a1} = received!(set, 1.0, "msg:a1", "sessA", "hi")
    {set, recv_b1} = received!(set, 2.0, "msg:b1", "sessB", "yo")
    {set, recv_a2} = received!(set, 3.0, "msg:a2", "sessA", "ok")
    {set, recv_b2} = received!(set, 4.0, "msg:b2", "sessB", "hm")
    {set, _} = remember!(set, 5.0, "ent:x", "aurora tide fjord", [recv_a1, recv_b1])
    {set, _} = remember!(set, 6.0, "ent:y", "fjord kayak gear", [recv_a2])
    {set, _} = remember!(set, 7.0, "ent:z", "aurora tide report", [recv_b2])
    set
  end

  test "AC10: three-way A/B — precision byte-equal across Stub, precision mode, assoc mode; divergent bounded" do
    set = store!()
    query = %{session_id: "sessA", prompt: "the aurora tide fjord crossing"}

    assert {:ok, precision} = Retriever.retrieve(query, %{store: set})
    assert precision != []

    # the stub leg answers the same list behind the same seam
    assert MemoryPort.Stub.retrieve(query, %{memories: precision}) == {:ok, precision}

    # the assoc leg carries the UNCHANGED precision list plus bounded channels
    assert {:ok, %{memory_ids: ^precision, associations: associations}} =
             Retriever.retrieve(query, %{store: set, assoc: true})

    assert length(associations.divergent) in 0..2

    # the wire legs: stub and precision emit byte-equal request envelopes;
    # the assoc leg's memoryPointers open with the untruncated precision list
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        50.0,
        "msg:q",
        "chan:1",
        "sessA",
        "the aurora tide fjord crossing"
      )

    assert {:ok, received} = signed |> Wire.envelope() |> Store.verify()
    view = [%{id: received.id, claims: received.claims}]

    emit = fn memory ->
      handler =
        ContextBuilder.handler(seed: @agent_seed, store: fn -> set end, memory: memory)

      assert [request] = handler.(view)
      request
    end

    stub_wire = emit.({MemoryPort.Stub, %{memories: precision}})
    precision_wire = emit.({Retriever, %{store: set}})
    assoc_wire = emit.({Retriever, %{store: set, assoc: true}})

    assert stub_wire == precision_wire

    pointer_ids = fn wire ->
      assert {:ok, verified} = Store.verify(wire)
      for {:delta, id, _ctx} <- Schema.resolve(verified.claims).memoryPointers, do: id
    end

    assert pointer_ids.(precision_wire) == precision
    assert Enum.take(pointer_ids.(assoc_wire), length(precision)) == precision
  end

  test "the divergent cap is boot-overridable through the retriever state key" do
    set = store!()
    query = %{session_id: "sessA", prompt: "the aurora tide fjord crossing"}

    assert {:ok, %{associations: %{divergent: [_z]}}} =
             Retriever.retrieve(query, %{store: set, assoc: true})

    assert {:ok, %{associations: %{divergent: []}}} =
             Retriever.retrieve(query, %{store: set, assoc: true, divergent_cap: 0})
  end

  test "normalize/1: the T11c list gains empty channels; the associative shape passes through" do
    assert ContextBuilder.normalize({:ok, ["a", "b"]}) ==
             %{memory_ids: ["a", "b"], associations: %{seeds: [], resonant: [], divergent: []}}

    shaped = %{memory_ids: ["a"], associations: %{seeds: ["s"], resonant: [], divergent: ["d"]}}
    assert ContextBuilder.normalize({:ok, shaped}) == shaped
  end

  test "window/2: the exact T11b tail split, shared by the engine and Saturation" do
    turns = Enum.map(1..10, &%{content: "turn #{&1}"})

    assert {elided, windowed} = ContextBuilder.window(turns)
    assert {elided, windowed} == Enum.split(turns, max(length(turns) - 8, 0))
    assert length(elided) == 2 and length(windowed) == 8

    assert ContextBuilder.window(turns, 12) == {[], turns}
  end
end
