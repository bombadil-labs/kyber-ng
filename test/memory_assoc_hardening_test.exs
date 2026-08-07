defmodule Kyber.Agent.MemoryAssocHardeningTest do
  @moduledoc """
  T13 hardening (2026-08-07, post-premortem): the premortem's defect-class
  carries, pinned as regression tests BEFORE the lib fixes land — each test
  fails for the right reason on the merged tree, then goes green with the
  fix. Covers: restart determinism (the wire round-trip), cite-fan
  boundedness, the conversation_ref window discipline (repeated prompts),
  normalize/1 refusing instead of crashing, human_author parity between the
  precision and association legs, the divergent_cap ceiling, df-saturated
  steady-state decay, and cold-start (empty seeds ⇒ empty channels).
  """

  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Events, Keys, Store, Wire}
  alias Kyber.Agent.ContextBuilder
  alias Kyber.Agent.Events, as: AgentEvents
  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.Assoc
  alias Kyber.Agent.Memory.Assoc.Index
  alias Kyber.Agent.Memory.Assoc.Saturation

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

  defp remember!(set, seed, ts, entity_id, content, sources) do
    {:ok, signed} = AgentEvents.memory_entity(seed, ts, entity_id, content, sources)
    admit!(set, signed)
  end

  defp walk(set, prompt, session_id, opts \\ []) do
    index = Index.build(set)
    seeds = Assoc.seeds(index, %{session_id: session_id, prompt: prompt}, [])
    Assoc.walk(index, seeds, Assoc.digests(prompt), Keyword.put(opts, :session_id, session_id))
  end

  test "restart determinism: the store round-trips through the wire and the walk is byte-identical" do
    set = DeltaSet.new()
    {set, recv} = received!(set, 1.0, "msg:q", "sq", "hi")
    {set, _} = remember!(set, @agent_seed, 2.0, "e:pin", "quartz beacon", [recv])
    {set, _} = remember!(set, @agent_seed, 3.0, "e:far", "marble ember", [])

    # the persistence path: every wire JSON-encoded, decoded, re-admitted
    # (the daemon's restart does exactly this — re-verify + re-merge)
    rebuilt =
      Enum.reduce(set, DeltaSet.new(), fn {_id, {claims, sig}}, acc ->
        wire = Wire.envelope({claims, sig})
        {:ok, json} = Wire.encode(wire)
        assert {:ok, decoded} = Wire.decode(json)
        assert {:ok, acc} = Store.admit(decoded, acc)
        acc
      end)

    before = walk(set, "quartz", "sq")
    after_restart = walk(rebuilt, "quartz", "sq")

    assert after_restart == before
  end

  test "cite-fan boundedness: an entity keeps at most the cite-fan cap, however many deltas cite it" do
    set = DeltaSet.new()
    {set, recv} = received!(set, 1.0, "msg:q", "sq", "hi")
    {set, _} = remember!(set, @agent_seed, 2.0, "e:pin", "quartz beacon", [recv])
    head = Memory.canon(set, "e:pin").head

    cite = fn set, i ->
      {:ok, signed} =
        AgentEvents.inference_requested(
          @agent_seed,
          10.0 + i,
          "model:1",
          "sq",
          "msg:q",
          "prompt:#{i}",
          [head]
        )

      admit!(set, signed)
    end

    {set_8, _} = Enum.reduce(1..8, {set, nil}, fn i, {set, _} -> cite.(set, i) end)
    {set_40, _} = Enum.reduce(1..40, {set, nil}, fn i, {set, _} -> cite.(set, i) end)

    cite_count = fn set ->
      index = Index.build(set)

      index.by_entity["e:pin"]
      |> Enum.count(&match?({:cite, _}, &1))
    end

    assert cite_count.(set_40) <= cite_count.(set_8)
    assert cite_count.(set_40) <= 8
  end

  test "conversation_ref window: a repeated prompt windows strictly below its OWN (last) occurrence" do
    set = DeltaSet.new()
    {set, t1} = received!(set, 1.0, "msg:one", "sq", "charlie beacon")
    {set, t2} = received!(set, 2.0, "msg:two", "sq", "bravo beacon")
    {set, _t3} = received!(set, 3.0, "msg:three", "sq", "charlie beacon")

    # e1 shares a digest with the FIRST occurrence only; e2 with the middle
    # turn. Both sit strictly below the LAST occurrence of the prompt.
    {set, _} = remember!(set, @agent_seed, 4.0, "e:one", "charlie alpha", [t1])
    {set, _} = remember!(set, @agent_seed, 5.0, "e:two", "bravo alpha", [t2])

    prefetch = Saturation.prefetch(set, "sq", "charlie beacon")
    head_two = Memory.canon(set, "e:two").head

    # the middle turn's entity seeds ONLY if the window includes it — i.e.
    # strictly below the LAST "charlie beacon", not the first
    assert head_two in prefetch.seeds
  end

  test "normalize/1 refuses a third shape instead of crashing" do
    assert %{memory_ids: [], associations: %{seeds: [], resonant: [], divergent: []}} =
             ContextBuilder.normalize({:ok, %{unexpected: "shape"}})

    # a half-shaped map keeps its precision ids, gains empty channels —
    # never silently zeroed (review round 2)
    assert %{memory_ids: ["a", "b"], associations: %{seeds: [], resonant: [], divergent: []}} =
             ContextBuilder.normalize({:ok, %{memory_ids: ["a", "b"]}})
  end

  test "human_author parity: the association leg ranks human-sourced entities like the precision leg" do
    set = DeltaSet.new()
    {set, recv} = received!(set, 1.0, "msg:q", "sq", "hi")

    # h:mem is a HUMAN EDITED memory (base + human edit with a NON-default
    # reason — the reason-string fallback only fires on "human_edit", so
    # only the author key wire tiers it :human): OLDER canon, so without
    # the human_author wire the recency tie puts a:mem first; with it, the
    # human provenance ranks above auto regardless of recency
    {set, base_h} =
      remember!(set, @human_seed, 1.5, "h:mem", "quartz human v1", [recv])

    {:ok, signed} =
      AgentEvents.memory_edited(@human_seed, 2.0, base_h, "quartz human", "human_touched")

    {set, _} = admit!(set, signed)

    {set, _} = remember!(set, @agent_seed, 3.0, "a:mem", "quartz agent", [recv])

    seeded = fn index ->
      Assoc.seeds(index, %{session_id: "sq", prompt: "quartz"}, [])
    end

    blind = seeded.(Index.build(set))
    wired = seeded.(Index.build(set, human_author: Keys.author_for_seed(@human_seed)))

    assert List.first(wired) == "h:mem"
    assert List.first(blind) == "a:mem"
  end

  test "divergent_cap is ceilinged: a boot override cannot unboundedly grow the channel" do
    set = DeltaSet.new()
    {set, recv} = received!(set, 1.0, "msg:q", "sq", "hi")

    # the seed carries ten DISTINCT rare digests (alpha_i + bravo_i, each
    # df exactly 2: seed + filler_i); the ten sourceless fillers are each
    # divergent-eligible (two rare shared digests, no direct link) — so
    # without the ceiling the override would return all ten
    {set, _} =
      remember!(
        set,
        @agent_seed,
        2.0,
        "e:seed",
        "quartz " <> Enum.map_join(1..10, " ", &"alpha#{&1} bravo#{&1}"),
        [recv]
      )

    {set, _} =
      Enum.reduce(1..10, {set, nil}, fn i, {set, _} ->
        {set, _} =
          remember!(set, @agent_seed, 3.0 + i, "e:fill#{i}", "alpha#{i} bravo#{i}", [])

        {set, nil}
      end)

    result = walk(set, "quartz", "sq", divergent_cap: 100)
    assert length(result.divergent) <= 8
    assert length(result.divergent) >= 1
  end

  test "df-saturated steady state: when shared digests exceed @max_df the divergent channel decays gracefully" do
    set = DeltaSet.new()
    {set, recv} = received!(set, 1.0, "msg:q", "sq", "hi")
    {set, _} = remember!(set, @agent_seed, 2.0, "e:seed", "quartz beacon", [recv])

    # five entities all carry the "quartz" digest: df(quartz) = 6 > 2, so
    # nothing shared with the pool is rare — the channel is empty, never a
    # crash and never a fabricated link
    {set, _} =
      Enum.reduce(1..5, {set, nil}, fn i, {set, _} ->
        {set, _} = remember!(set, @agent_seed, 3.0 + i, "e:q#{i}", "quartz filler#{i}", [recv])
        {set, nil}
      end)

    result = walk(set, "quartz", "sq")
    assert result.divergent == []
    assert result.resonant != []
  end

  test "cold start: a session with no entities yields empty seeds and empty channels" do
    set = DeltaSet.new()
    {set, _} = received!(set, 1.0, "msg:q", "other", "hi")
    {set, _} = remember!(set, @agent_seed, 2.0, "e:pin", "quartz beacon", [])

    result = walk(set, "quartz", "fresh-session")
    assert result.resonant == []
    assert result.divergent == []
    assert result.edges_walked == 0
  end
end
