defmodule Kyber.Agent.IdempotenceTest do
  @moduledoc """
  T14b AC3 — idempotence enforced and OBSERVED: a duplicate ToolCall (same
  content-derived id) executes ONCE; the duplicate is acked (the stored
  ToolResult re-emitted byte-identical) and observed (exactly one
  ToolCallDuplicate per (call, result) pair — same ts + ids derive the
  same observation id, so merge-is-union collapses the record), never
  re-executed and never refused.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Action, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @request_id String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0

  defmodule RecordingHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def get(url, _headers, state) do
      send(state.reply_to, {:http_get, url})
      {:ok, %{status: 200, body: "ok"}}
    end

    @impl true
    def post(url, _headers, body, state) do
      send(state.reply_to, {:http_post, url, body})
      {:ok, %{status: 200, body: "ok"}}
    end
  end

  defp tmp_workspace do
    ws = Path.join(System.tmp_dir!(), "kyber-t14b-idem-#{System.os_time()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    ws
  end

  defp run(set, call, ws) do
    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: Action.registry(),
        gate: Gate.new(default: :allow),
        context: Action.context(workspace: ws, http: {RecordingHttp, %{reply_to: self()}}),
        store: fn -> set end
      )

    handler.([call])
  end

  defp absorb(set, wires) do
    Enum.reduce(wires, set, fn wire, s ->
      {:ok, delta} = Store.verify(wire)
      Map.put(s, delta.id, {delta.claims, wire["sig"]})
    end)
  end

  defp resolve_wire(wire) do
    {:ok, delta} = Store.verify(wire)
    Schema.resolve(delta.claims)
  end

  defp of_type(set, type) do
    Enum.filter(set, fn {_id, {claims, _sig}} ->
      match?(%{type: ^type}, Schema.resolve(claims))
    end)
  end

  # ------------------------------------------------------------------ tests

  test "AC3: the same ToolCall delta three times — one request, one ToolResult, exactly one ToolCallDuplicate" do
    ws = tmp_workspace()

    {:ok, {policy_claims, policy_sig}} =
      AgentEvents.policy(@agent_seed, @ts, "url_policy", ["allowed.example"], ["https"])

    set = %{Delta.id_hex(policy_claims) => {policy_claims, policy_sig}}

    {:ok, signed} =
      AgentEvents.tool_call(
        @agent_seed,
        @ts + 1,
        "http.get",
        JSON.encode!(%{"url" => "https://allowed.example/once"}),
        @request_id
      )

    {:ok, call} = Store.verify(Wire.envelope(signed))

    # the original executes
    assert [gate_wire, result_wire] = run(set, call, ws)
    assert %{type: "ToolResult", status: "ok"} = resolve_wire(result_wire)
    assert_received {:http_get, "https://allowed.example/once"}
    set = absorb(set, [gate_wire, result_wire])

    # the first duplicate: answer first (stored ToolResult byte-identical),
    # then the observation — acked, never refused, never silent
    assert [^gate_wire, ^result_wire, dup_wire] = run(set, call, ws)
    dup = resolve_wire(dup_wire)
    assert dup.type == "ToolCallDuplicate"
    assert dup.dedupes == {:delta, call.id, "deduplicated"}
    {:ok, result_delta} = Store.verify(result_wire)
    assert dup.result == {:delta, result_delta.id, "observed"}

    # the duplicate's observation claims the CALL's timestamp
    {:ok, dup_delta} = Store.verify(dup_wire)
    assert dup_delta.claims.timestamp == call.claims.timestamp
    set = absorb(set, [gate_wire, result_wire, dup_wire])

    # the second duplicate derives the SAME observation id — merge-is-union
    # collapses to exactly one record per (call, result) pair
    assert [^gate_wire, ^result_wire, ^dup_wire] = run(set, call, ws)
    set = absorb(set, [gate_wire, result_wire, dup_wire])

    # the side effect happened exactly once across original + duplicates
    refute_received {:http_get, _}

    assert [_one_result] = of_type(set, "ToolResult")
    assert [_one_dup] = of_type(set, "ToolCallDuplicate")
  end

  test "AC3: a refused call's duplicate emits no observation — nothing executed, nothing to dedupe" do
    ws = tmp_workspace()

    {:ok, {policy_claims, policy_sig}} =
      AgentEvents.policy(@agent_seed, @ts, "url_policy", ["allowed.example"], ["https"])

    set = %{Delta.id_hex(policy_claims) => {policy_claims, policy_sig}}

    {:ok, signed} =
      AgentEvents.tool_call(
        @agent_seed,
        @ts + 1,
        "http.get",
        JSON.encode!(%{"url" => "https://denied.example/"}),
        @request_id
      )

    {:ok, call} = Store.verify(Wire.envelope(signed))

    assert [refusal_wire] = run(set, call, ws)
    assert %{verdict: "refuse", policy: "url_policy"} = resolve_wire(refusal_wire)
    set = absorb(set, [refusal_wire])

    # the stored refusal is re-emitted byte-identical; no ToolResult, no
    # ToolCallDuplicate, no request — reject, never repair
    assert [^refusal_wire] = run(set, call, ws)
    refute_received {:http_get, _}
    assert [] = of_type(set, "ToolCallDuplicate")
  end
end
