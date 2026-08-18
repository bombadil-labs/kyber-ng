defmodule Kyber.Agent.ActionGateTest do
  @moduledoc """
  T12 AC2 — the gate is the boundary: an allow-listed action runs; a denied
  action emits NO `ToolResult` and a refused-reason claim; the gate's
  decisions are attested deltas (auditable — verified-signed through the one
  door, pointer-linked to the call they decide); a `prompt`-policy action is
  refused when no prompt answer is wired (fail closed).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Action, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents

  @agent_seed String.duplicate("b2", 32)
  @fixture_content "the oracle answer is 42"

  defp tmp_workspace do
    ws = Path.join(System.tmp_dir!(), "kyber-t12-gate-#{System.os_time()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "notes.txt"), @fixture_content)
    on_exit(fn -> File.rm_rf(ws) end)
    ws
  end

  defp start_store, do: elem(Agent.start_link(fn -> %{} end), 1)

  defp call_delta(store, tool_id, args, ts, request_ref \\ String.duplicate("cd", 32)) do
    {:ok, signed} =
      AgentEvents.tool_call(@agent_seed, ts, tool_id, args, request_ref)

    wire = Wire.envelope(signed)
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp executor(store, workspace, gate) do
    ToolExecutor.handler(
      seed: @agent_seed,
      tools: Action.registry(),
      gate: gate,
      context: Action.context(workspace: workspace),
      store: fn -> Agent.get(store, & &1) end
    )
  end

  defp persist(store, wires) do
    Enum.each(wires, fn wire ->
      {:ok, delta} = Store.verify(wire)
      Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    end)
  end

  defp typed(wire, type) do
    {:ok, delta} = Store.verify(wire)

    case Schema.resolve(delta.claims) do
      %{type: ^type} = typed -> typed
      other -> flunk("expected a #{type}, got: #{inspect(other)}")
    end
  end

  defp results_for(store, call_id) do
    store
    |> Agent.get(& &1)
    |> Enum.filter(fn {_id, {claims, _sig}} ->
      match?(%{type: "ToolResult", call: {:delta, ^call_id, _}}, Schema.resolve(claims))
    end)
  end

  # ------------------------------------------------------------------ tests

  test "AC2: an allow-listed action runs, and the decision is an attested delta" do
    workspace = tmp_workspace()
    store = start_store()
    gate = Gate.new(allow: ["fs.read"])

    call =
      call_delta(store, "fs.read", JSON.encode!(%{"path" => "notes.txt"}), 1_700_000_000_000.0)

    assert [gate_wire, result_wire] = executor(store, workspace, gate).([call])

    # the decision verifies through the one door — signed by the agent,
    # pointer-linked to the call it decides (auditable by construction)
    {:ok, gate_delta} = Store.verify(gate_wire)
    assert gate_delta.claims.author == Keys.author_for_seed(@agent_seed)

    decision = Schema.resolve(gate_delta.claims)
    assert decision.type == "GateDecision"
    assert decision.decides == {:delta, call.id, "decided"}
    assert decision.verdict == "allow"
    assert decision.policy == "allow"

    result = typed(result_wire, "ToolResult")
    assert result.call == {:delta, call.id, "result"}
    assert result.result == @fixture_content
    assert result.status == "ok"
  end

  test "AC2: a denied action emits NO ToolResult and a refused-reason claim — it never runs" do
    workspace = tmp_workspace()
    store = start_store()
    gate = Gate.new(deny: ["sh.run"])

    # the message -> request chain first: MessageSent (id M, content) ->
    # InferenceRequested (promptRef -> M, id R) — the projection keys the
    # exchange on M and joins the steps through R
    {:ok, msg} =
      Kyber.Events.message_sent(
        @agent_seed,
        1_700_000_000_000.0,
        "resp:dummy",
        "msg:1",
        "ch:1",
        "play ping"
      )

    msg_wire = Wire.envelope(msg)
    Agent.update(store, &Map.put(&1, msg_wire["id"], msg))

    {:ok, req} =
      AgentEvents.inference_requested(
        @agent_seed,
        1_700_000_000_000.0,
        "kimi-k3",
        "sess",
        "cd",
        msg_wire["id"],
        []
      )

    req_wire = Wire.envelope(req)
    Agent.update(store, &Map.put(&1, req_wire["id"], req))

    call =
      call_delta(
        store,
        "sh.run",
        JSON.encode!(%{"command" => "touch gated-marker.txt"}),
        1_700_000_000_000.0,
        req_wire["id"]
      )

    assert [gate_wire] = executor(store, workspace, gate).([call])
    persist(store, [gate_wire])

    decision = typed(gate_wire, "GateDecision")
    assert decision.decides == {:delta, call.id, "decided"}
    assert decision.verdict == "deny"
    assert decision.policy == "deny"
    assert decision.reason == "denied by policy"

    # no ToolResult, and the side effect never happened — reject, never repair
    assert results_for(store, call.id) == []
    refute File.exists?(Path.join(workspace, "gated-marker.txt"))

    # the refused step is VISIBLE in the projection (fold: C's refusal_of/2)
    # — the reason renders as the result, the status is "refused", and the
    # audit trail surfaces in the lens, not just the store
    set = Agent.get(store, & &1)
    assert {:ok, exchange} = Kyber.Agent.Projection.exchange(set, msg_wire["id"])
    assert [step] = exchange.steps
    assert step.tool == "sh.run"
    assert step.status == "refused"
    assert step.result == "denied by policy"
  end

  test "AC2: a prompt-policy action with no prompt answer wired is refused (fail closed)" do
    workspace = tmp_workspace()
    store = start_store()
    gate = Gate.new(prompt: ["sh.run"])

    call =
      call_delta(
        store,
        "sh.run",
        JSON.encode!(%{"command" => "touch prompted-marker.txt"}),
        1_700_000_000_000.0
      )

    assert [gate_wire] = executor(store, workspace, gate).([call])
    persist(store, [gate_wire])

    decision = typed(gate_wire, "GateDecision")
    assert decision.verdict == "refuse"
    assert decision.policy == "prompt"
    assert decision.reason =~ "fail closed"

    assert results_for(store, call.id) == []
    refute File.exists?(Path.join(workspace, "prompted-marker.txt"))
  end

  test "AC2: a wired prompt answer decides — allow runs, deny refuses" do
    workspace = tmp_workspace()
    store = start_store()

    allowing =
      Gate.new(prompt: ["sh.run"], prompt_handler: fn "sh.run", _args -> :allow end)

    denying =
      Gate.new(prompt: ["sh.run"], prompt_handler: fn "sh.run", _args -> :deny end)

    call =
      call_delta(
        store,
        "sh.run",
        JSON.encode!(%{"command" => "touch answered-marker.txt"}),
        1_700_000_000_000.0
      )

    # the wired allow runs the action and attests the prompt policy
    assert [gate_wire, result_wire] = executor(store, workspace, allowing).([call])
    persist(store, [gate_wire, result_wire])

    decision = typed(gate_wire, "GateDecision")
    assert decision.verdict == "allow"
    assert decision.policy == "prompt"

    assert typed(result_wire, "ToolResult").status == "ok"
    assert File.exists?(Path.join(workspace, "answered-marker.txt"))

    # the wired deny refuses — no ToolResult, no side effect
    denied_call =
      call_delta(
        store,
        "sh.run",
        JSON.encode!(%{"command" => "touch denied-marker.txt"}),
        1_700_000_000_001.0
      )

    assert [denied_gate_wire] = executor(store, workspace, denying).([denied_call])
    persist(store, [denied_gate_wire])

    denied = typed(denied_gate_wire, "GateDecision")
    assert denied.verdict == "deny"
    assert denied.policy == "prompt"

    assert results_for(store, denied_call.id) == []
    refute File.exists?(Path.join(workspace, "denied-marker.txt"))
  end

  test "AC2: fail closed by default — an unlisted action is denied without a policy entry" do
    workspace = tmp_workspace()
    store = start_store()
    gate = Gate.new(allow: ["fs.read"])

    call =
      call_delta(
        store,
        "fs.write",
        JSON.encode!(%{"path" => "unlisted.txt", "content" => "nope"}),
        1_700_000_000_000.0
      )

    assert [gate_wire] = executor(store, workspace, gate).([call])
    persist(store, [gate_wire])

    decision = typed(gate_wire, "GateDecision")
    assert decision.verdict == "deny"
    assert decision.reason =~ "default deny"

    assert results_for(store, call.id) == []
    refute File.exists?(Path.join(workspace, "unlisted.txt"))
  end

  test "AC2: the store outranks a changed policy — a re-fired call re-emits the stored decision" do
    workspace = tmp_workspace()
    store = start_store()

    call =
      call_delta(store, "fs.read", JSON.encode!(%{"path" => "notes.txt"}), 1_700_000_000_000.0)

    first = executor(store, workspace, Gate.new(allow: ["fs.read"])).([call])
    assert [_gate_wire, _result_wire] = first
    persist(store, first)

    # the human tightens the list after the crash — the replay does NOT
    # re-decide: the persisted decision is the authority (the chain is the
    # state), re-emitted byte-identical
    # (T14b: the re-fire also carries the ToolCallDuplicate observation —
    # the stored decision + result stay byte-identical, never re-decided)
    refired = executor(store, workspace, Gate.new(deny: ["fs.read"])).([call])
    assert [gate_refire, result_refire, _dup_wire] = refired
    assert [gate_refire, result_refire] == first
  end

  test "AC2: decide/2 is the pure policy reading (the boot-resolved posture)" do
    gate = Gate.new(allow: ["fs.read"], prompt: ["sh.run"])

    assert %{verdict: :allow, policy: :allow, reason: nil} = Gate.decide(gate, "fs.read")
    assert %{verdict: :refuse, policy: :prompt} = Gate.decide(gate, "sh.run")
    assert %{verdict: :deny, policy: :deny} = Gate.decide(gate, "fs.write")

    assert %{verdict: :deny, policy: :deny, reason: "denied by policy"} =
             Gate.decide(Gate.new(%{"sh.run" => :deny}), "sh.run")
  end
end
