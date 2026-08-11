defmodule Kyber.Agent.SkillFoldTest do
  @moduledoc """
  T14f AC1 — the fold: a skill's current view is DERIVED from its deltas
  (set, supersede, retract) — deterministic, no wall-clock; a skill is a
  VIEW, never a blob (the set holds only deltas; the view is empty until
  they are folded). AC4's lineage round-trip (update + remove + restore with
  the stream intact) and the probe-2 liveness oracle (H3) live here too.

  The fold orders by `{claims.timestamp, id}` (D2 — total, content-derived,
  replica-identical; NOT append order), version counts ALL the name's
  set-deltas (D3/L6 — retraction-immune, re-creation continues the count),
  supersede is WHOLE-SET across deltas (H6 — an absent optional role is
  CLEARED), and liveness is RECURSIVE-EXISTENTIAL through the whole negation
  chain (D4/H3 — a skill is not-found iff its order-head set-delta is
  retracted; restore = negate every live negation of that head; a non-head
  retraction is a silent no-op; removal of the head never exposes the prior
  version).
  """
  use ExUnit.Case, async: false

  alias Kyber.Agent.{Events, Skill}
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @ts 1_700_000_000_000.0

  # ------------------------------------------------------------ scaffolding

  # each mint returns {id, {claims, sig}} — the DeltaSet PAIR (the set's
  # entry); set_of/1 builds a set from pairs (union is order-free)
  defp skill_set(name, description, body, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    metadata = Keyword.get(opts, :metadata)
    source = Keyword.get(opts, :source)

    {:ok, {claims, sig}} =
      Events.skill_set(@agent_seed, ts, name, description, body, metadata, source)

    {Delta.id_hex(claims), {claims, sig}}
  end

  defp skill_retract(name, head_id, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts + 1)

    {:ok, {claims, sig}} = Events.skill_retract(@agent_seed, ts, name, head_id)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp set_of(elements) do
    Map.new(elements, fn {claims, _sig} = element -> {Delta.id_hex(claims), element} end)
  end

  # --------------------------------------------------------------- AC1 fold

  test "AC1: the view is empty until the deltas are folded — a skill is a view, never a blob" do
    # no deltas -> no skill: the set holds no blob, the fold answers not-found
    assert Skill.view(%{}, "greet") == :not_found

    {set_id, set_pair} = skill_set("greet", "Greet a new member", "say hello")
    set = set_of([set_pair])

    # the set holds EXACTLY the minted delta — one SkillSet, no aggregate
    # blob claim, no stored "current skill"
    assert map_size(set) == 1
    assert Map.has_key?(set, set_id)

    # the fold derives the view from that single delta
    assert {:ok, view} = Skill.view(set, "greet")
    assert view.name == "greet"
    assert view.description == "Greet a new member"
    assert view.body == "say hello"
    assert view.metadata == nil
    assert view.source == nil
    assert view.version == 1
    assert view.head == set_id
    # the fold's timestamp is the delta's CLAIMED timestamp — never wall-clock
    assert view.timestamp == @ts

    # a name with no deltas stays not-found
    assert Skill.view(set, "other") == :not_found
  end

  test "AC1: set — one full-set delta carries the whole property set (name/description/body + optional metadata + source pointer)" do
    {set_id, set_pair} =
      skill_set("deploy", "Deploy the service", "mix release", metadata: "{}", source: "call:1")

    assert {:ok, view} = Skill.view(set_of([set_pair]), "deploy")
    assert view.description == "Deploy the service"
    assert view.body == "mix release"
    assert view.metadata == "{}"
    assert view.source == {:delta, "call:1", "triggered"}
    assert view.version == 1
    assert view.head == set_id
  end

  test "AC1: supersede is WHOLE-SET — the latest full-set delta wins, an ABSENT optional role is CLEARED (H6)" do
    {s1_id, s1} = skill_set("greet", "desc v1", "body v1", metadata: "m1")
    {s2_id, s2} = skill_set("greet", "desc v2", "body v2", ts: @ts + 1)
    set = set_of([s1, s2])

    assert {:ok, view} = Skill.view(set, "greet")
    assert view.description == "desc v2"
    assert view.body == "body v2"
    # S2 omits metadata -> the omitted optional role is CLEARED, never sticky
    assert view.metadata == nil
    assert view.version == 2
    assert view.head == s2_id
    refute view.head == s1_id
  end

  test "AC1: fold order is {timestamp, id} — same-timestamp sets tie on the content-derived id (D2)" do
    {s1_id, s1} = skill_set("tie", "v1", "body1")
    {s2_id, s2} = skill_set("tie", "v2", "body2")
    # identical timestamps: the fold must pick the LARGER content id — the
    # total, content-derived order — never map iteration / append order
    set = set_of([s1, s2])
    head_id = max(s1_id, s2_id)
    expected = if head_id == s1_id, do: "v1", else: "v2"

    assert {:ok, view} = Skill.view(set, "tie")
    assert view.head == head_id
    assert view.description == expected
  end

  test "AC1: the fold is a pure function of the set — construction order cannot change the view" do
    {s1_id, s1} = skill_set("order", "v1", "body1")
    {_s2_id, s2} = skill_set("order", "v2", "body2", ts: @ts + 1)
    # a NON-head retraction (silent no-op) rides the same set — the fold must
    # answer the same view regardless of how the set was assembled
    {_r_id, r} = skill_retract("order", s1_id, ts: @ts + 2)

    # two different construction orders merge to the SAME set (Map.merge is
    # union — forward-admit == reverse-admit), and the fold answers the same
    forward = set_of([s1, s2, r])
    reverse = set_of(Enum.reverse([s1, s2, r]))
    assert forward == reverse

    assert Skill.view(forward, "order") == Skill.view(reverse, "order")
    assert {:ok, view} = Skill.view(forward, "order")
    assert view.description == "v2"
  end

  # ------------------------------------------------------------ probe-2 oracle (H3)

  test "probe-2 B: set + remove — the skill is not-found (recursive: live=false)" do
    {s_id, s} = skill_set("p2b", "desc", "body")
    {_r_id, r} = skill_retract("p2b", s_id)
    set = set_of([s, r])

    assert Skill.view(set, "p2b") == :not_found
  end

  test "probe-2 C: remove + restore — LIVE (flat negation would kill restore; AC4)" do
    {s_id, s} = skill_set("p2c", "desc", "body")
    {r_id, r} = skill_retract("p2c", s_id)
    {_r2_id, r2} = skill_retract("p2c", r_id)
    set = set_of([s, r, r2])

    assert {:ok, view} = Skill.view(set, "p2c")
    assert view.description == "desc"
    assert view.body == "body"
    assert view.version == 1
  end

  test "probe-2 D: DOUBLE-remove + SINGLE-restore — not-found (existential inertness: every live removal must be negated)" do
    {s_id, s} = skill_set("p2d", "desc", "body")
    {r1_id, r1} = skill_retract("p2d", s_id, ts: @ts + 1)
    {r2_id, r2} = skill_retract("p2d", s_id, ts: @ts + 2)
    {_r3_id, r3} = skill_retract("p2d", r1_id, ts: @ts + 3)
    set = set_of([s, r1, r2, r3])

    assert Skill.view(set, "p2d") == :not_found
  end

  test "probe-2 E: double-remove + double-restore — LIVE" do
    {s_id, s} = skill_set("p2e", "desc", "body")
    {r1_id, r1} = skill_retract("p2e", s_id, ts: @ts + 1)
    {r2_id, r2} = skill_retract("p2e", s_id, ts: @ts + 2)
    {_r3_id, r3} = skill_retract("p2e", r1_id, ts: @ts + 3)
    {_r4_id, r4} = skill_retract("p2e", r2_id, ts: @ts + 4)
    set = set_of([s, r1, r2, r3, r4])

    assert {:ok, view} = Skill.view(set, "p2e")
    assert view.description == "desc"
  end

  test "probe-2 F: restore then RE-REMOVE the restore — not-found (liveness recomputed per read, never latched)" do
    {s_id, s} = skill_set("p2f", "desc", "body")
    {r1_id, r1} = skill_retract("p2f", s_id)
    {r2_id, r2} = skill_retract("p2f", r1_id)
    {_r3_id, r3} = skill_retract("p2f", r2_id)
    set = set_of([s, r1, r2, r3])

    assert Skill.view(set, "p2f") == :not_found
  end

  # ------------------------------------------------------- head semantics (H2)

  test "H2: retraction of a NON-head set-delta is a silent no-op — the head still rules" do
    {s1_id, s1} = skill_set("nop", "v1", "body1")
    {s2_id, s2} = skill_set("nop", "v2", "body2", ts: @ts + 1)
    {_r_id, r} = skill_retract("nop", s1_id)
    set = set_of([s1, s2, r])

    assert {:ok, view} = Skill.view(set, "nop")
    assert view.description == "v2"
    assert view.head == s2_id
  end

  test "H2: removing the head NEVER exposes the prior version (no retraction-path rollback)" do
    {_s1_id, s1} = skill_set("rollback", "v1", "body1")
    {s2_id, s2} = skill_set("rollback", "v2", "body2", ts: @ts + 1)
    {_r_id, r} = skill_retract("rollback", s2_id)
    set = set_of([s1, s2, r])

    # NOT-FOUND — the prior v1 is NOT re-exposed; rollback is a NEW
    # superseding set, forward-only
    assert Skill.view(set, "rollback") == :not_found
  end

  # ------------------------------------------------------ version (D3/L6) + lineage

  test "D3/L6: version counts ALL the name's set-deltas — retraction-immune, remove/restore keeps it stable" do
    {_s1_id, s1} = skill_set("ver", "v1", "body1")
    {s2_id, s2} = skill_set("ver", "v2", "body2", ts: @ts + 1)
    {r_id, r} = skill_retract("ver", s2_id)
    {_r2_id, r2} = skill_retract("ver", r_id)
    set = set_of([s1, s2, r, r2])

    assert {:ok, view} = Skill.view(set, "ver")
    # the full remove+restore round-trip never renumbers the history
    assert view.version == 2
    assert view.description == "v2"
  end

  test "L6/N3: re-creation continues the count — a fresh set after a retraction is a NEW lineage, never renumbered" do
    {s1_id, s1} = skill_set("recreate", "v1", "body1")
    {_r_id, r} = skill_retract("recreate", s1_id)
    {_s2_id, s2} = skill_set("recreate", "v2", "body2", ts: @ts + 2)
    set = set_of([s1, r, s2])

    # the re-created skill lives with ITS properties (re-creation beats
    # revival), and the version continues from the pre-removal count
    assert {:ok, view} = Skill.view(set, "recreate")
    assert view.description == "v2"
    assert view.version == 2
  end

  test "AC4: update + remove + restore round-trip — the stream is intact throughout (auditability)" do
    {s1_id, s1} = skill_set("lineage", "v1", "body1")
    {s2_id, s2} = skill_set("lineage", "v2", "body2", ts: @ts + 1)
    {r1_id, r1} = skill_retract("lineage", s2_id, ts: @ts + 2)
    {r2_id, r2} = skill_retract("lineage", r1_id, ts: @ts + 3)
    set = set_of([s1, s2, r1, r2])

    # the restored view is the LATEST set (v2) — the head was never exposed
    assert {:ok, view} = Skill.view(set, "lineage")
    assert view.description == "v2"

    # the STREAM holds every delta — nothing is deleted, ever; the full
    # history is auditably present
    for id <- [s1_id, s2_id, r1_id, r2_id], do: assert(Map.has_key?(set, id))
    assert map_size(set) == 4
  end

  test "D2: the fold never reads wall-clock — every view timestamp is a claimed delta timestamp" do
    {_s1_id, s1} = skill_set("clock", "v1", "body1")
    {_s2_id, s2} = skill_set("clock", "v2", "body2", ts: @ts + 42)
    set = set_of([s1, s2])

    assert {:ok, view} = Skill.view(set, "clock")
    assert view.timestamp == @ts + 42
    # the same set folds to the same view every time — a pure function
    assert Skill.view(set, "clock") == {:ok, view}
  end

  test "AC1: views/1 — every LIVE skill's fold, sorted by name, never the raw streams" do
    {_a_id, a} = skill_set("alpha", "A skill", "body a")
    {_b_id, b} = skill_set("beta", "B skill", "body b")
    {g_id, g} = skill_set("gamma", "G skill", "body g")
    {_r_id, r} = skill_retract("gamma", g_id)
    set = set_of([a, b, g, r])

    # gamma is retracted (not-found) — only alpha and beta ride, sorted by name
    assert Enum.map(Skill.views(set), & &1.name) == ["alpha", "beta"]
    assert [%{name: "alpha"}, %{name: "beta"}] = Skill.views(set)
  end
end
