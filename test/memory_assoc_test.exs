defmodule Kyber.Agent.MemoryAssocTest do
  @moduledoc """
  T13 AC1 — the walk is pure and bounded: `Index.build` and `walk` are
  deterministic (same store + query → same result, twice), the walk respects
  max depth (2) and max candidates (frontier ≤ 32), and content-feature
  edges come from SHA-256 digests of the tokens — never prose matching.
  Fixed timestamps 1.0, 2.0, … throughout (no wall-clock).
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Store, Wire}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Memory.Assoc
  alias Kyber.Agent.Memory.Assoc.Index

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

  # seed entity in session "sq"; hops are SOURCELESS (digest edges only) so
  # reachability is exactly the token chain: seed -linkone- hop1 -linktwo-
  # hop2 -(cyan/dune, never expanded)- hop3
  defp depth_store do
    set = DeltaSet.new()
    {set, recv_q} = received!(set, 1.0, "msg:q", "sq", "hi")
    {set, _} = remember!(set, 2.0, "e:seed", "alpha linkone", [recv_q])
    {set, _} = remember!(set, 3.0, "e:hop1", "linkone linktwo", [])
    {set, _} = remember!(set, 4.0, "e:hop2", "linktwo cyan dune", [])
    {set, _} = remember!(set, 5.0, "e:hop3", "linkthree cyan dune", [])
    set
  end

  # one seed in "sq"; `fillers` plain depth-1 neighbors sharing only "quartz";
  # nb:33 (OLDEST — ranks last by the sort tuple) is the only path to e:far,
  # whose rare pool overlap (marble, ember) makes it divergent-eligible; all
  # neighbors sourceless so no session feature shortcuts the walk
  defp frontier_store(fillers) do
    set = DeltaSet.new()
    {set, recv_q} = received!(set, 1.0, "msg:q", "sq", "hi")
    {set, _} = remember!(set, 3.0, "e:seed", "quartz beacon", [recv_q])
    {set, _} = remember!(set, 4.0, "nb:33", "quartz zenith", [])
    {set, _} = remember!(set, 5.0, "e:far", "marble ember zenith", [])

    Enum.reduce(1..fillers, set, fn i, set ->
      n = String.pad_leading(Integer.to_string(i), 2, "0")
      {set, _} = remember!(set, 5.0 + i, "nb:#{n}", "quartz filler#{n}", [])
      set
    end)
  end

  defp walk(set, prompt, session_id) do
    index = Index.build(set)
    seeds = Assoc.seeds(index, %{session_id: session_id, prompt: prompt}, [])
    Assoc.walk(index, seeds, Assoc.digests(prompt), session_id: session_id)
  end

  test "determinism: Index.build twice ==, walk twice ==" do
    set = depth_store()

    assert Index.build(set) == Index.build(set)

    index = Index.build(set)
    seeds = Assoc.seeds(index, %{session_id: "sq", prompt: "alpha cyan dune"}, [])
    query_digests = Assoc.digests("alpha cyan dune")

    assert seeds == Assoc.seeds(index, %{session_id: "sq", prompt: "alpha cyan dune"}, [])

    assert Assoc.walk(index, seeds, query_digests, session_id: "sq") ==
             Assoc.walk(index, seeds, query_digests, session_id: "sq")
  end

  test "depth bound: a 2-hop neighbor is collected, a 3-hop neighbor never is" do
    result = walk(depth_store(), "alpha cyan dune", "sq")

    # e:hop2 is reachable in two hops (seed -linkone- hop1 -linktwo- hop2),
    # shares {cyan, dune} with the query (df 2 each — rare), no direct link
    assert "e:hop2" in result.divergent
    refute "e:hop3" in (result.resonant ++ result.divergent)
    refute "e:hop1" in result.divergent
    assert result.edges_walked > 0
  end

  test "candidate bound: the frontier is capped at @max_candidates (32)" do
    # 32 depth-1 neighbors (31 fillers + nb:33): nb:33 makes the frontier,
    # its zenith edge reaches e:far at depth 2 — divergent surfaces it
    in_bounds = walk(frontier_store(31), "quartz beacon marble ember", "sq")
    assert "e:far" in in_bounds.divergent

    # 33 depth-1 neighbors: nb:33 (oldest — last in the sort tuple) is cut
    # from the frontier, so e:far is unreachable — the cap binds
    over = walk(frontier_store(32), "quartz beacon marble ember", "sq")
    refute "e:far" in (over.resonant ++ over.divergent)
  end

  test "edges are digests: token-different prose shares no digest feature; shared tokens share the SHA-256" do
    set = DeltaSet.new()
    {set, recv_q} = received!(set, 1.0, "msg:q", "sq", "hi")
    {set, _} = remember!(set, 2.0, "e:one", "cerulean harbor", [recv_q])
    {set, _} = remember!(set, 3.0, "e:two", "crimson meadow", [recv_q])
    {set, _} = remember!(set, 4.0, "e:three", "cerulean skyline", [recv_q])

    index = Index.build(set)

    shared_one_two = MapSet.intersection(index.by_entity["e:one"], index.by_entity["e:two"])
    refute Enum.any?(shared_one_two, &match?({:digest, _}, &1))
    # they DO share the session feature — association is not prose matching
    assert {:session, "sq"} in shared_one_two

    cerulean = Base.encode16(:crypto.hash(:sha256, "cerulean"), case: :lower)
    assert {:digest, cerulean} in index.by_entity["e:one"]

    assert MapSet.member?(index.by_feature[{:digest, cerulean}], "e:three")
    refute MapSet.member?(index.by_feature[{:digest, cerulean}], "e:two")
  end
end
