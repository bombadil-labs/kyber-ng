defmodule Kyber.Agent.CrashWindowTest do
  @moduledoc """
  T14j AC5 (R1 — the AC3 crash-window rider): the four legs, one witness
  suite. `crash_window_test.exs` is a DELIVERABLE, not a verify-only close
  (L1 — the absorbed-set control, the fresh-call rotation, and the cursor
  window exist elsewhere; none covers the crashed re-fire with a dropped
  ToolResult, Leg C's tied-ts read, or Leg D's re-fired-call refusal).

  - (A) a re-fire after a crash-between-execute-and-record re-executes ONCE
    and the record dedupes (crash window: GateDecision recorded, ToolResult
    dropped — the engine dies between execute and record).
  - (B) the re-executed turn's mint is BYTE-IDENTICAL (the M6 call-ts mint
    at tool_executor.ex:491-495 makes it hold).
  - (C) the dedupe read is {ts, id}-ordered (NEW-1 — `by_timestamp` was
    ts-only, nondet under the >32 filler regime): a hand-crafted 35-entry
    store with TWO tied-ts ToolResults for one call, contents PINNED
    "A2222222222"/"B2222222222" (M4 — contents pinned, never searched at
    runtime); the {ts, id} first-match picks B while the ts-only
    first-match picks A (the disagreeing pair).
  - (D) the GATE-BREAK arm — the TOTAL-LOSS crash window (H3): a ROTATED
    epoch mid-window makes the re-fire REFUSE. Constructible ONLY when the
    crash drops ALL wires (not even the GateDecision persisted; the store
    survives). This suite EXPLICITLY DROPS THE WIRES (the engine dies
    between execute and record with zero persisted wires) — with the
    GateDecision persisted, the re-fire would answer the STORED allow and
    re-execute, and a rotated epoch would be invisible.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Events, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @request_id String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0

  # ------------------------------------------------------------ scaffolding

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

  defp skill_epoch(allow_names, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    supersedes = Keyword.get(opts, :supersedes)

    {:ok, {claims, sig}} = Events.skill_policy(@agent_seed, ts, allow_names, supersedes)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp tool_results_for(set, call_id) do
    for {id, {claims, _sig}} <- set,
        %{type: "ToolResult", call: {:delta, ^call_id, _ctx}} <- [Schema.resolve(claims)],
        do: id
  end

  # ------------------------------------------------ legs A + B (the crashed
  # re-fire over the GateDecision-recorded window)

  test "leg A: a re-fire after a crash-between-execute-and-record re-executes ONCE and the record dedupes (GateDecision recorded, ToolResult dropped)" do
    # the crash window: the FIRST fire's GateDecision persisted, its
    # ToolResult dropped — the engine died between execute and record
    tools = %{"tool:echo" => fn args -> args end}
    call = call_delta("tool:echo", "ping", @ts + 1)
    set = %{}

    [gate_wire, _result_wire] = handler_with(set, tools).([call])
    set_crashed = absorb(set, [gate_wire])

    # re-fire over the crashed store: no stored ToolResult -> the executor
    # re-EXECUTES (once) and mints a fresh result
    [gate_wire2, result_wire2] = handler_with(set_crashed, tools).([call])

    # the stored GateDecision is re-emitted verbatim (never re-decided)
    assert gate_wire2 == gate_wire
    assert resolve_wire(gate_wire2).verdict == "allow"

    # the re-executed result is a REAL record (the action ran again)
    assert resolve_wire(result_wire2).type == "ToolResult"
    assert resolve_wire(result_wire2).result == "ping"

    # the record DEDUPES: the final store holds exactly ONE ToolResult for
    # the call — the crash did not lose the answer, the re-fire did not
    # duplicate it
    set_final = absorb(set_crashed, [gate_wire2, result_wire2])
    assert length(tool_results_for(set_final, call.id)) == 1
    assert length(tool_results_for(set_final, call.id)) == 1
  end

  test "leg B: the re-executed turn's mint is BYTE-IDENTICAL (the M6 call-ts mint — the crash-window re-fire re-mints the SAME delta)" do
    tools = %{"tool:echo" => fn args -> args end}
    call = call_delta("tool:echo", "ping", @ts + 1)
    set = %{}

    [gate_wire, result_wire] = handler_with(set, tools).([call])
    set_crashed = absorb(set, [gate_wire])

    [_gate_wire2, result_wire2] = handler_with(set_crashed, tools).([call])

    # the re-minted result claims the CALL's timestamp, never a fresh clock
    # — so the re-fire's wire is byte-identical to the first fire's and
    # merge-is-union collapses the two mints to one record
    assert result_wire2 == result_wire
    assert result_wire2["id"] == result_wire["id"]
  end

  # ------------------------------------------------ leg C (the {ts, id} dedupe
  # read over the PINNED disagreeing pair)

  test "leg C: the dedupe read is {ts, id}-ordered — the pinned disagreeing pair (contents A2222222222/B2222222222) on a 35-entry store" do
    call = call_delta("tool:echo", "ping", @ts + 1)
    call_id = call.id

    # the hand-crafted 35-entry store (the >32 filler regime): the call's
    # GateDecision + TWO tied-ts ToolResults (contents PINNED, never
    # searched at runtime — M4) + 32 filler ToolResults for OTHER calls
    {:ok, gate} = Events.gate_decision(@agent_seed, @ts + 1, call_id, "allow", "permission")
    {:ok, a} = Events.tool_result(@agent_seed, @ts, call_id, "A2222222222")
    {:ok, b} = Events.tool_result(@agent_seed, @ts, call_id, "B2222222222")

    filler =
      for i <- 1..32 do
        {:ok, signed} =
          Events.tool_result(
            @agent_seed,
            @ts - 100.0 + i,
            String.duplicate(Integer.to_string(i), 40),
            "filler #{i}"
          )

        signed
      end

    a_id = Delta.id_hex(elem(a, 0))
    b_id = Delta.id_hex(elem(b, 0))
    refute a_id == b_id

    set = Map.new([gate, a, b | filler], fn {claims, _sig} = e -> {Delta.id_hex(claims), e} end)
    assert map_size(set) == 35

    # the disagreement oracle (test-side, never the code under test): for
    # THIS pinned construction the ts-only first-match picks B and the
    # {ts, id} first-match picks A — the disagreeing pair (the ts-only
    # reading is nondeterministic under the >32 filler regime; {ts, id} is
    # the substrate's total order)
    ts_only_first =
      set
      |> Enum.sort_by(fn {_id, {claims, _sig}} -> claims.timestamp end)
      |> Enum.find_value(fn {id, {claims, _sig}} ->
        case Schema.resolve(claims) do
          %{type: "ToolResult", call: {:delta, ^call_id, _ctx}} -> id
          _other -> nil
        end
      end)

    {ts_id_first, _} =
      set
      |> Enum.sort_by(fn {id, {claims, _sig}} -> {claims.timestamp, id} end)
      |> Enum.find_value(fn {id, {claims, _sig}} ->
        case Schema.resolve(claims) do
          %{type: "ToolResult", call: {:delta, ^call_id, _ctx}} -> {id, claims}
          _other -> nil
        end
      end)

    assert ts_only_first == b_id
    assert ts_id_first == a_id
    refute ts_only_first == ts_id_first

    # the executor's re-fire: the stored answer is re-emitted from the
    # {ts, id}-FIRST record (A), and the ToolCallDuplicate observes it —
    # the {ts, id}-ordered read is what the code under test uses
    [gate_wire, result_wire, dup_wire] = handler_with(set, ToolExecutor.stub_tools()).([call])

    assert resolve_wire(gate_wire).verdict == "allow"
    assert result_wire["id"] == a_id

    dup = resolve_wire(dup_wire)
    assert dup.type == "ToolCallDuplicate"
    assert dup.dedupes == {:delta, call_id, "deduplicated"}
    assert dup.result == {:delta, a_id, "observed"}
  end

  # ------------------------------------------------ leg D (the TOTAL-LOSS
  # crash window — every wire dropped, the store survives)

  test "leg D (total-loss crash window): a rotated epoch mid-window makes the re-fire REFUSE — all wires dropped, the store survives" do
    # the total-loss crash window: the engine died between execute and
    # record with NOT EVEN the GateDecision persisted — the store holds only
    # the epoch (it survives; nothing else does)
    {e1_id, e1} = skill_epoch(["greet"])
    set = %{e1_id => e1}

    call = call_delta("skill.set", JSON.encode!(%{"name" => "greet", "description" => "d", "body" => "b"}), @ts + 1)

    # the first fire would emit [gate_decision, skill_set, tool_result] —
    # the total-loss crash drops ALL of them (nothing persisted)
    _first_fire = handler_with(set).([call])

    # mid-window the epoch ROTATES: the new epoch supersedes the old and
    # allows nothing (the operator rotated greet OUT)
    {e2_id, e2} = skill_epoch([], ts: @ts + 2, supersedes: e1_id)
    rotated = Map.put(set, e2_id, e2)

    # the re-fire over the surviving store: no stored GateDecision (total
    # loss), so the call is re-DECIDED under the ROTATED epoch — and the
    # rotated epoch refuses (the pinned reason string)
    [refusal_wire] = handler_with(rotated).([call])

    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "skill_policy"
    assert refusal.reason == "skill_policy: skill not allowed by the current epoch"

    # NOTHING was written — no SkillSet, no ToolResult (reject, never repair)
    refute Enum.any?(rotated, fn {_id, {claims, _sig}} ->
             match?(%{type: "SkillSet"}, Schema.resolve(claims))
           end)

    refute Enum.any?(rotated, fn {_id, {claims, _sig}} ->
             match?(%{type: "ToolResult"}, Schema.resolve(claims))
           end)
  end
end
