defmodule Kyber.Agent.IdentityFoldTest do
  @moduledoc """
  T14g AC3/AC4 + G4 — the identity fold: soul/user/operator are DERIVED
  entities, a view over their `IdentitySet` delta stream (never a blob),
  AUTHOR-FILTERED FIRST (H2): the stream is pre-filtered to the boot-
  constant `operator_author`'s claims BEFORE `{ts, id}` ordering — an
  agent's newer inert write can never SHADOW the operator's live soul
  (ordering DoS closed) — and negations are author-filtered too (an agent
  cannot retract the soul out-of-band). Liveness is the SKILL fold's
  liveness VERBATIM via the SHARED `Kyber.Agent.Liveness` helper (M1): the
  probe-2 truth table (B dead / C live / D dead / E live / F dead) is the
  oracle, witnessed through the REAL DOOR (`Store.admit` — Store.verify +
  union, the T14f D4 discipline). Operator rotation (N8): the fold's author
  is BOOT-CONSTANT — a rotated operator's identity docs are fold-inert at
  the next boot: "the old persona never re-renders post-rotation".
  """
  use ExUnit.Case, async: false

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Events, Identity}
  alias Rhizomatic.Delta

  @operator_seed String.duplicate("7f", 32)
  @rotated_seed String.duplicate("8a", 32)
  @agent_seed String.duplicate("b7", 32)
  @ts 1_700_000_000_000.0

  @operator_author Keys.author_for_seed(@operator_seed)

  # each mint returns {id, {claims, sig}} — the DeltaSet PAIR; set_of/1
  # builds a set from pairs (union is order-free)
  defp identity_set(id, kind, body, opts \\ []) do
    seed = Keyword.get(opts, :seed, @operator_seed)
    ts = Keyword.get(opts, :ts, @ts)

    {:ok, {claims, sig}} = Events.identity_set(seed, ts, id, kind, body)
    {Delta.id_hex(claims), {claims, sig}}
  end

  # an identity removal rides a RAW negation (L2 — no retraction builder
  # exists; the operator hand-rolls it; the negator scan stays kind-agnostic)
  defp raw_negation(target_id, opts \\ []) do
    seed = Keyword.get(opts, :seed, @operator_seed)
    ts = Keyword.get(opts, :ts, @ts + 1)

    claims = %{
      timestamp: ts,
      author: Keys.author_for_seed(seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, sig} = Keys.sign(claims, seed)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp set_of(elements) do
    Map.new(elements, fn {claims, _sig} = element -> {Delta.id_hex(claims), element} end)
  end

  # the REAL DOOR: admit every wire through Store.verify + union (the
  # probe-2 discipline — the fold's input is admitted, never hand-assembled)
  defp admit_set(pairs) do
    Enum.reduce(pairs, %{}, fn {claims, sig}, set ->
      wire = Wire.envelope({claims, sig})
      {:ok, %{id: _id, claims: ^claims}} = Store.verify(wire)
      {:ok, merged} = Store.admit(wire, set)
      merged
    end)
  end

  # --------------------------------------------------------------- the fold

  test "AC4: the fold is a pure function of the author's stream — {ts, id}-ordered, latest-wins, replica-identical" do
    {_s1_id, s1} = identity_set("identity:soul", "soul", "v1 body")
    {_s2_id, s2} = identity_set("identity:soul", "soul", "v2 body", ts: @ts + 1)
    set = set_of([s1, s2])

    assert {:ok, %{body: "v2 body", head: _head}} = Identity.primitive(set, @operator_author, "soul")

    # same-timestamp tie: the fold picks the LARGER content id — the total,
    # content-derived order, never map/append order
    {t1_id, t1} = identity_set("identity:user", "user", "u1", ts: @ts)
    {t2_id, t2} = identity_set("identity:user", "user", "u2", ts: @ts)
    tie = set_of([t1, t2])
    head_id = max(t1_id, t2_id)
    expected = if head_id == t1_id, do: "u1", else: "u2"

    assert {:ok, view} = Identity.primitive(tie, @operator_author, "user")
    assert view.head == head_id
    assert view.body == expected
  end

  test "AC3: an AGENT-signed identity write is door-admissible but FOLD-INERT — never renders, never shadows (M6)" do
    {_op_id, op} = identity_set("identity:soul", "soul", "operator soul")
    # a NEWER agent-signed soul — would shadow under an author-blind fold
    {_ag_id, ag} = identity_set("identity:soul", "soul", "agent soul", seed: @agent_seed, ts: @ts + 10)
    set = admit_set([op, ag])

    # both admit through the one door (the door is signer-agnostic)
    assert map_size(set) == 2

    # the fold answers the OPERATOR's body — the agent's inert write never
    # shadows (H2a — ordering DoS closed)
    assert {:ok, %{body: "operator soul"}} = Identity.primitive(set, @operator_author, "soul")

    # and the block never renders the agent's body
    refute "Soul: agent soul" in Identity.block(set, @operator_author, nil)
    assert "Soul: operator soul" in Identity.block(set, @operator_author, nil)
  end

  test "AC3: an AGENT-signed negation cannot retract the operator's soul out-of-band (H2b)" do
    {op_id, op} = identity_set("identity:soul", "soul", "operator soul")
    {_ag_r, ag_r} = raw_negation(op_id, seed: @agent_seed, ts: @ts + 10)
    set = admit_set([op, ag_r])

    # the agent's negation admits (door signer-agnostic) but is author-
    # filtered OUT of the liveness scan — the soul stays live
    assert {:ok, %{body: "operator soul"}} = Identity.primitive(set, @operator_author, "soul")
  end

  test "AC3: an AGENT-signed ProfileSet cannot escalate visibility — the declaration is fold-inert (H2c)" do
    {:ok, {claims, sig}} =
      Events.profile_set(@agent_seed, @ts, "expected-name", "escalate", [], [], ["memory"])

    wire = Wire.envelope({claims, sig})
    {:ok, _} = Store.verify(wire)

    # an author-filtered resolve sees NO declaration — the name is unknown
    # (attach refuses with {:error, {:unknown_profile, "expected-name"}})
    assert Kyber.Agent.Profile.resolve(
             %{Delta.id_hex(claims) => {claims, sig}},
             @operator_author,
             "expected-name"
           ) == :not_found
  end

  # ------------------------------------------------- probe-2 oracle (H3, verbatim)

  test "probe-2 B: set + remove — the primitive is not-found (recursive: live=false)" do
    {s_id, s} = identity_set("identity:soul", "soul", "body")
    {_r_id, r} = raw_negation(s_id)
    set = admit_set([s, r])

    assert Identity.primitive(set, @operator_author, "soul") == :not_found
  end

  test "probe-2 C: remove + restore — LIVE (flat negation would kill restore; the shared helper)" do
    {s_id, s} = identity_set("identity:soul", "soul", "body")
    {r_id, r} = raw_negation(s_id)
    {r2_id, r2} = raw_negation(r_id, ts: @ts + 2)
    set = admit_set([s, r, r2])

    assert {:ok, %{body: "body"}} = Identity.primitive(set, @operator_author, "soul")
  end

  test "probe-2 D: DOUBLE-remove + SINGLE-restore — not-found (existential inertness)" do
    {s_id, s} = identity_set("identity:soul", "soul", "body")
    {r1_id, r1} = raw_negation(s_id, ts: @ts + 1)
    {_r2_id, r2} = raw_negation(s_id, ts: @ts + 2)
    {_r3_id, r3} = raw_negation(r1_id, ts: @ts + 3)
    set = admit_set([s, r1, r2, r3])

    assert Identity.primitive(set, @operator_author, "soul") == :not_found
  end

  test "probe-2 E: double-remove + double-restore — LIVE" do
    {s_id, s} = identity_set("identity:soul", "soul", "body")
    {r1_id, r1} = raw_negation(s_id, ts: @ts + 1)
    {r2_id, r2} = raw_negation(s_id, ts: @ts + 2)
    {_r3_id, r3} = raw_negation(r1_id, ts: @ts + 3)
    {_r4_id, r4} = raw_negation(r2_id, ts: @ts + 4)
    set = admit_set([s, r1, r2, r3, r4])

    assert {:ok, %{body: "body"}} = Identity.primitive(set, @operator_author, "soul")
  end

  test "probe-2 F: restore then RE-REMOVE the restore — not-found (liveness recomputed per read, never latched)" do
    {s_id, s} = identity_set("identity:soul", "soul", "body")
    {r1_id, r1} = raw_negation(s_id)
    {r2_id, r2} = raw_negation(r1_id, ts: @ts + 2)
    {_r3_id, r3} = raw_negation(r2_id, ts: @ts + 3)
    set = admit_set([s, r1, r2, r3])

    assert Identity.primitive(set, @operator_author, "soul") == :not_found
  end

  # -------------------------------------------------------- head semantics

  test "G2: removing the head NEVER exposes the prior version (no retraction-path rollback)" do
    {_s1_id, s1} = identity_set("identity:soul", "soul", "v1")
    {s2_id, s2} = identity_set("identity:soul", "soul", "v2", ts: @ts + 1)
    {_r_id, r} = raw_negation(s2_id, ts: @ts + 2)
    set = admit_set([s1, s2, r])

    assert Identity.primitive(set, @operator_author, "soul") == :not_found
  end

  test "G2: removal rides RAW negations — restore = negate every live negation of the head; the stream stays intact" do
    {s1_id, s1} = identity_set("identity:soul", "soul", "v1")
    {s2_id, s2} = identity_set("identity:soul", "soul", "v2", ts: @ts + 1)
    {r_id, r} = raw_negation(s2_id, ts: @ts + 2)
    {_r2_id, r2} = raw_negation(r_id, ts: @ts + 3)
    set = admit_set([s1, s2, r, r2])

    assert {:ok, %{body: "v2"}} = Identity.primitive(set, @operator_author, "soul")

    # the STREAM holds every delta — nothing is deleted, ever
    for id <- [s1_id, s2_id, r_id], do: assert(Map.has_key?(set, id))
  end

  # -------------------------------------------------- closed set + inertness

  test "G1/N3: the kind set is CLOSED — an unknown or whitespace kind/id never folds (inert, never repaired)" do
    {_banana_id, banana} = identity_set("identity:banana", "banana", "not a primitive")
    {_ws_kind_id, ws_kind} = identity_set("identity:soul", " ", "whitespace kind")
    {_ws_id_id, ws_id} = identity_set(" ", "soul", "whitespace id")
    set = admit_set([banana, ws_kind, ws_id])

    assert Identity.primitive(set, @operator_author, "soul") == :not_found
    # the closed set never folds an unknown kind — the block renders nothing
    assert Identity.block(set, @operator_author, nil) == []
    assert Identity.primitives(set, @operator_author) == %{}
  end

  # ---------------------------------------------------- operator rotation (N8)

  test "N8: operator rotation — the OLD persona never re-renders post-rotation (the fold's author is boot-constant)" do
    {_op_id, op} = identity_set("identity:soul", "soul", "the old persona")
    {_u_id, u} = identity_set("identity:user", "user", "old operator prefs")
    set = admit_set([op, u])

    # boot under the OLD operator: the block renders
    block = Identity.block(set, @operator_author, nil)
    assert "Soul: the old persona" in block
    assert "User: old operator prefs" in block

    # boot under the ROTATED operator (a fresh seed): the old docs are
    # fold-inert — the block renders NOTHING (the old persona never
    # re-renders; no crash, no fail-open leak)
    rotated_author = Keys.author_for_seed(@rotated_seed)
    assert Identity.block(set, rotated_author, nil) == []
    assert Identity.primitive(set, rotated_author, "soul") == :not_found

    # the new operator's own docs render under the new boot
    {_n_id, n} = identity_set("identity:soul", "soul", "the new persona", seed: @rotated_seed, ts: @ts + 1)
    rotated_set = admit_set([op, u, n])
    assert "Soul: the new persona" in Identity.block(rotated_set, rotated_author, nil)
    refute "Soul: the old persona" in Identity.block(rotated_set, rotated_author, nil)
  end

  test "M1: the shared liveness helper is ONE implementation — identity and skill answer through the same recursive-existential" do
    # the helper's shape: parameterized by the negator filter; skill passes
    # identity (author-blind), identity passes the boot-constant author
    {s_id, s} = identity_set("identity:user", "user", "u body")
    {_r_id, r} = raw_negation(s_id)
    set = set_of([s, r])

    assert Kyber.Agent.Liveness.live?(set, s_id, fn _claims -> true end) == false
    assert Kyber.Agent.Liveness.live?(set, s_id, fn _claims -> true end) ==
             Kyber.Agent.Liveness.live?(set, s_id, fn claims -> claims.author == @operator_author end)
  end
end
