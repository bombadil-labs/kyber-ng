defmodule Kyber.Agent.SkillGateTest do
  @moduledoc """
  T14f AC2 — the skill permission seam: skill writes (set AND retract — a
  retraction is a write to the same aggregate) and skill.read all route
  through the gate's THIRD policy layer, `skill_policy`, chained AFTER
  `memory_policy` (L1 — appended LAST, the regression-frozen order), over
  the memory-family `allow_entity` `{:entity, name, "writable"}` context
  (D5 — ZERO Policy genesis change; one allowlist governs all three
  surfaces, L3).

  The layer is fail-closed from birth: ungoverned => `no governing epoch`,
  forked => `epoch forked`, governed => the allowlist check with its own
  reason string `skill not allowed by the current epoch` (M5 — the third
  reason; check_memory/2 would answer the memory_policy dialect). Epoch
  arms precede args decode (the T14d norm).

  Emission (D10/M6): a write emits [gate_decision, skill_set, tool_result]
  in that order; the SkillSet/SkillRetract mint claims the CALL's
  `claims.timestamp` — never a fresh clock — so a crash-window re-fire
  re-mints the SAME delta and record-dedupe holds. A replayed write is
  absorbed, never re-applied. The gate runs BEFORE resolution, so
  retract-of-unknown and read-of-unknown reach the `{"", "unknown_entity"}`
  dialect (D8) only when the name is allowlisted (no existence oracle).
  """
  use ExUnit.Case, async: false

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Events, Skill, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @request_id String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0

  # ------------------------------------------------------------ scaffolding

  defp skill_epoch(allow_names, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    supersedes = Keyword.get(opts, :supersedes)

    {:ok, {claims, sig}} = Events.skill_policy(@agent_seed, ts, allow_names, supersedes)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp call_delta(tool, args, ts) do
    {:ok, signed} = Events.tool_call(@agent_seed, ts, tool, args, @request_id)
    {:ok, call} = Store.verify(Wire.envelope(signed))
    call
  end

  defp handler_with(set, tools \\ nil) do
    ToolExecutor.handler(
      seed: @agent_seed,
      tools: tools || ToolExecutor.skill_tools(fn -> set end),
      gate: Gate.new(default: :allow),
      store: fn -> set end
    )
  end

  defp resolve_wire(wire) do
    {:ok, delta} = Store.verify(wire)
    Schema.resolve(delta.claims)
  end

  defp absorb(set, wires) do
    Enum.reduce(wires, set, fn wire, s ->
      {:ok, delta} = Store.verify(wire)
      Map.put(s, delta.id, {delta.claims, wire["sig"]})
    end)
  end

  defp set_args(name, description, body, opts \\ []) do
    JSON.encode!(%{
      "name" => name,
      "description" => description,
      "body" => body,
      "metadata" => Keyword.get(opts, :metadata)
    })
  end

  # ------------------------------------------------------------ AC2: the gate

  test "AC2 ungoverned: skill.set is refused fail-closed — no governing epoch, NO SkillSet, NO ToolResult" do
    handler = handler_with(%{})
    call = call_delta("skill.set", set_args("greet", "d", "b"), @ts + 1)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "skill_policy"
    assert refusal.reason == "skill_policy: no governing epoch (fail closed)"
  end

  test "AC2 ungoverned: skill.retract AND skill.read are refused too — the whole surface fails closed" do
    handler = handler_with(%{})

    for tool <- ["skill.retract", "skill.read"] do
      call = call_delta(tool, JSON.encode!(%{"name" => "greet"}), @ts + 1)
      assert [refusal_wire] = handler.([call])
      refusal = resolve_wire(refusal_wire)
      assert refusal.type == "GateDecision"
      assert refusal.verdict == "refuse"
      assert refusal.policy == "skill_policy"
      assert refusal.reason == "skill_policy: no governing epoch (fail closed)"
    end
  end

  test "AC2 forked: two live skill epochs — epoch forked (fail closed), nothing written" do
    {e1_id, e1} = skill_epoch(["greet"])
    {e2_id, e2} = skill_epoch(["greet"], ts: @ts + 1)
    set = %{e1_id => e1, e2_id => e2}
    handler = handler_with(set)
    call = call_delta("skill.set", set_args("greet", "d", "b"), @ts + 2)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "skill_policy"
    assert refusal.reason == "skill_policy: epoch forked (fail closed)"
  end

  test "AC2 governed allow: skill.set emits [gate_decision, skill_set, tool_result] — the SkillSet mints the CALL's timestamp (M6)" do
    {epoch_id, epoch} = skill_epoch(["greet"])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.set", set_args("greet", "Greet a member", "say hello"), @ts + 1)

    assert [gate_wire, skill_wire, result_wire] = handler.([call])

    decision = resolve_wire(gate_wire)
    assert decision.type == "GateDecision"
    assert decision.verdict == "allow"
    assert decision.decides == {:delta, call.id, "decided"}

    skill = resolve_wire(skill_wire)
    assert skill.type == "SkillSet"
    assert skill.skill == {:entity, "greet", "skills"}
    assert skill.description == "Greet a member"
    assert skill.body == "say hello"
    # the provenance pointer rides the triggering call (D1), and the mint
    # claims the CALL's timestamp — never a fresh clock (M6)
    assert skill.source == {:delta, call.id, "triggered"}
    assert skill.timestamp == call.claims.timestamp

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.status == "ok"
    assert result.result == "set skill greet"
  end

  test "AC2 governed refuse: the third reason string — skill not allowed by the current epoch (M5), epoch pointer, NO write" do
    {epoch_id, epoch} = skill_epoch(["greet"])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.set", set_args("classified", "d", "b"), @ts + 1)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "skill_policy"
    assert refusal.reason == "skill_policy: skill not allowed by the current epoch"
    assert refusal.policy_epoch == {:delta, epoch_id, "under"}

    # NO SkillSet and NO ToolResult — nothing was written
    set_after = absorb(set, [refusal_wire])
    assert map_size(set_after) == 2
    refute Enum.any?(set_after, fn {_id, {claims, _sig}} ->
             match?(%{type: "SkillSet"}, Schema.resolve(claims))
           end)
  end

  test "AC2: skill.read is gated like memory.read — an allowed read returns the FOLD" do
    {epoch_id, epoch} = skill_epoch(["greet"])
    {:ok, {set_claims, set_sig}} =
      Events.skill_set(@agent_seed, @ts, "greet", "Greet a member", "say hello")

    set_id = Delta.id_hex(set_claims)
    set = %{epoch_id => epoch, set_id => {set_claims, set_sig}}
    handler = handler_with(set)
    call = call_delta("skill.read", JSON.encode!(%{"name" => "greet"}), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.status == "ok"
    # the ToolResult IS the fold, rendered deterministically
    fold = JSON.decode!(result.result)
    assert fold["name"] == "greet"
    assert fold["description"] == "Greet a member"
    assert fold["body"] == "say hello"
    assert fold["version"] == 1
  end

  test ~s|AC2/D8: skill.read of an unknown name under a governing epoch — {"", "unknown_entity"}, a resolution outcome, never a refusal| do
    {epoch_id, epoch} = skill_epoch(["ghost"])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.read", JSON.encode!(%{"name" => "ghost"}), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.result == ""
    assert result.status == "unknown_entity"
  end

  test "AC2/D8: skill.read of a RETRACTED skill resolves unknown_entity too (retracted ≡ never-existed at the tool surface)" do
    {epoch_id, epoch} = skill_epoch(["gone"])
    {:ok, {s_claims, s_sig}} = Events.skill_set(@agent_seed, @ts, "gone", "d", "b")
    s_id = Delta.id_hex(s_claims)
    {:ok, {r_claims, r_sig}} = Events.skill_retract(@agent_seed, @ts + 1, "gone", s_id)
    r_id = Delta.id_hex(r_claims)
    set = %{epoch_id => epoch, s_id => {s_claims, s_sig}, r_id => {r_claims, r_sig}}
    handler = handler_with(set)
    call = call_delta("skill.read", JSON.encode!(%{"name" => "gone"}), @ts + 2)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.result == ""
    assert result.status == "unknown_entity"
  end

  test "AC2/D8: skill.retract of a LIVE skill mints the SkillRetract targeting the ORDER-HEAD (call-ts mint)" do
    {epoch_id, epoch} = skill_epoch(["greet"])
    {:ok, {s1_claims, s1_sig}} = Events.skill_set(@agent_seed, @ts, "greet", "v1", "b1")
    s1_id = Delta.id_hex(s1_claims)
    {:ok, {s2_claims, s2_sig}} = Events.skill_set(@agent_seed, @ts + 1, "greet", "v2", "b2")
    s2_id = Delta.id_hex(s2_claims)
    set = %{epoch_id => epoch, s1_id => {s1_claims, s1_sig}, s2_id => {s2_claims, s2_sig}}
    handler = handler_with(set)
    call = call_delta("skill.retract", JSON.encode!(%{"name" => "greet"}), @ts + 2)

    assert [gate_wire, retract_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"

    retract = resolve_wire(retract_wire)
    assert retract.type == "SkillRetract"
    assert retract.skill == {:entity, "greet", "skills"}
    # the negation targets the ORDER-HEAD set-delta — never a name, and
    # never the prior version (no retraction-path rollback)
    assert retract.negates == {:delta, s2_id, "retracted"}
    assert retract.timestamp == call.claims.timestamp

    result = resolve_wire(result_wire)
    assert result.status == "ok"
    assert result.result == "retracted skill greet"

    # the fold answers not-found now (head removed)
    set_after = absorb(set, [gate_wire, retract_wire, result_wire])
    assert Skill.view(set_after, "greet") == :not_found
  end

  test ~s|AC2/D8/L5: skill.retract of an UNKNOWN name — allowlisted but no live fold: no negation is minted, {"", "unknown_entity"}| do
    {epoch_id, epoch} = skill_epoch(["ghost"])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.retract", JSON.encode!(%{"name" => "ghost"}), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.result == ""
    assert result.status == "unknown_entity"

    # NO negation was minted (tool-boundary discipline — dangling negations
    # would be door-admissible, but this surface mints none)
    set_after = absorb(set, [gate_wire, result_wire])
    refute Enum.any?(set_after, fn {_id, {claims, _sig}} ->
             match?(%{type: "SkillRetract"}, Schema.resolve(claims))
           end)
  end

  test "N1: skill.set refuses a whitespace-only name at the TOOL BOUNDARY — reject, never repair, never normalized, no SkillSet" do
    {epoch_id, epoch} = skill_epoch(["   "])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.set", set_args("   ", "d", "b"), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.status == "error"
    assert result.result == "skill name must not be whitespace-only"

    # the stored name is never normalized and nothing was written
    set_after = absorb(set, [gate_wire, result_wire])
    refute Enum.any?(set_after, fn {_id, {claims, _sig}} ->
             match?(%{type: "SkillSet"}, Schema.resolve(claims))
           end)
  end

  test "D10/M6: a replayed write is absorbed, never re-applied — one SkillSet for the call, byte-identical re-emission" do
    {epoch_id, epoch} = skill_epoch(["greet"])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("skill.set", set_args("greet", "d", "b"), @ts + 1)

    call_id = call.id
    [gate_wire, skill_wire, result_wire] = handler.([call])
    set_after = absorb(set, [gate_wire, skill_wire, result_wire])

    # re-fire the SAME call over the absorbed set: the stored answer is
    # re-emitted byte-identically (gate + ToolResult + ToolCallDuplicate),
    # the write is NOT re-applied — no new SkillSet is minted or emitted
    [gate_wire2, result_wire2, dup_wire] = handler_with(set_after).([call])

    assert resolve_wire(gate_wire2).verdict == "allow"
    assert result_wire2 == result_wire

    dup = resolve_wire(dup_wire)
    assert dup.type == "ToolCallDuplicate"
    assert dup.dedupes == {:delta, call_id, "deduplicated"}

    # exactly ONE SkillSet claims this call's source in the final set
    set_final = absorb(set_after, [gate_wire2, result_wire2, dup_wire])
    skill_sets =
      for {id, {claims, _sig}} <- set_final,
          %{type: "SkillSet", source: {:delta, ^call_id, _}} <- [Schema.resolve(claims)],
          do: id

    assert length(skill_sets) == 1
  end
end
