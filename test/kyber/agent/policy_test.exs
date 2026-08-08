defmodule Kyber.Agent.PolicyTest do
  @moduledoc """
  T14b AC2 — policy epochs: a second policy claim supersedes the first,
  the gate consults the CURRENT epoch, a decision made under epoch 1
  stands (non-retroactivity — the stored decision is re-emitted
  byte-identical, never re-decided), and retraction (`negates`) revives
  the prior epoch without rewriting history. T14b AC5 — determinism:
  policy decisions derive from store state, epoch resolution is
  content-derived, no wall-clock in decisions (two fresh boots produce
  byte-identical wires; every emitted claim's ts equals its call's ts).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Action, Policy, ToolExecutor}
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

  # ---------------------------------------------------------------- helpers

  defp epoch_wire(hosts, schemes, ts, supersedes \\ nil) do
    {:ok, {claims, sig}} =
      AgentEvents.policy(@agent_seed, ts, "url_policy", hosts, schemes, supersedes)

    {Delta.id_hex(claims), {claims, sig}}
  end

  # retraction-is-negation: the substrate's only revocation verb
  defp negation_wire(target_id, ts) do
    raw = %{
      timestamp: ts,
      author: Keys.author_for_seed(@agent_seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, @agent_seed)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp tmp_workspace do
    ws = Path.join(System.tmp_dir!(), "kyber-t14b-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    ws
  end

  # a fresh "boot": a fresh handler closure over the given set (executor-
  # direct topology — the reactor companion lives in the url-gate file)
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

  defp call_delta(url, ts) do
    {:ok, signed} =
      AgentEvents.tool_call(
        @agent_seed,
        ts,
        "http.get",
        JSON.encode!(%{"url" => url}),
        @request_id
      )

    {:ok, call} = Store.verify(Wire.envelope(signed))
    call
  end

  # persist emissions back into the set — the executor's store-answer source
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

  # ------------------------------------------------------------------- AC2

  test "AC2: supersession, non-retroactivity, and negates-revival — history never rewritten" do
    ws = tmp_workspace()
    {e1_id, e1} = epoch_wire(["a.example"], ["https"], @ts)
    set = %{e1_id => e1}

    # call C executes under epoch 1 (1 request, decision G1)
    call_c = call_delta("https://a.example/c", @ts + 1)
    assert [g1_wire, r1_wire] = run(set, call_c, ws)
    assert %{type: "GateDecision", verdict: "allow"} = resolve_wire(g1_wire)
    assert_received {:http_get, "https://a.example/c"}
    set = absorb(set, [g1_wire, r1_wire])

    # epoch 2 — the revocation (M1 seed shape): nonempty schemes so the
    # scheme check passes and the empty host set refuses, making the
    # expected reason determinate under the scheme-then-host order
    {e2_id, e2} = epoch_wire([], ["https"], @ts + 2, e1_id)
    set = Map.put(set, e2_id, e2)
    assert {:ok, %{id: ^e2_id}} = Policy.current(set)

    # (i) re-fire C's delta: G1 re-emitted byte-identical (never re-decided
    # under epoch 2), still 1 request, one ToolCallDuplicate
    assert [^g1_wire, ^r1_wire, dup_wire] = run(set, call_c, ws)
    assert %{type: "ToolCallDuplicate"} = resolve_wire(dup_wire)
    refute_received {:http_get, _}

    # (ii) a fresh call, same URL, is refused under the CURRENT epoch
    call_c2 = call_delta("https://a.example/c", @ts + 3)
    assert [refusal_wire] = run(set, call_c2, ws)
    refused = resolve_wire(refusal_wire)
    assert refused.verdict == "refuse"
    assert refused.policy == "url_policy"
    assert refused.reason == "url_policy: host not allowed by the current epoch"
    assert refused.policy_epoch == {:delta, e2_id, "under"}
    refute_received {:http_get, _}

    # (iii) retract epoch 2: the prior epoch revives; a fresh call executes
    {n_id, n} = negation_wire(e2_id, @ts + 4)
    set = Map.put(set, n_id, n)
    assert {:ok, %{id: ^e1_id}} = Policy.current(set)

    call_c3 = call_delta("https://a.example/revived", @ts + 5)
    assert [_g3_wire, _r3_wire] = run(set, call_c3, ws)
    assert_received {:http_get, "https://a.example/revived"}

    # history is never rewritten: epoch 2's claim is STILL in the store,
    # so the (ii) refusal's policy_epoch pointer still resolves
    assert Map.has_key?(set, e2_id)
  end

  test "AC2: pure resolution — all epochs retracted is :none; a retracted claim is no superseder" do
    {e1_id, e1} = epoch_wire(["a.example"], ["https"], @ts)
    {e2_id, e2} = epoch_wire(["b.example"], ["https"], @ts + 1, e1_id)
    {n2_id, n2} = negation_wire(e2_id, @ts + 2)

    # retracted epoch 2 is inert: neither current nor a superseder
    set = %{e1_id => e1, e2_id => e2, n2_id => n2}
    assert {:ok, %{id: ^e1_id, allow_hosts: ["a.example"]}} = Policy.current(set)

    # retracting the whole chain leaves the family ungoverned
    {n1_id, n1} = negation_wire(e1_id, @ts + 3)
    assert :none = Policy.current(Map.put(set, n1_id, n1))

    # a foreign family never leaks into url_policy resolution
    assert :none = Policy.current(%{e1_id => e1}, "other_family")
  end

  test "AC2: two unsuperseded heads fork the epoch — {:error, :forked}" do
    {e1_id, e1} = epoch_wire(["a.example"], ["https"], @ts)
    {e2_id, e2} = epoch_wire(["b.example"], ["https"], @ts + 1)
    assert {:error, :forked} = Policy.current(%{e1_id => e1, e2_id => e2})
  end

  test "AC2: matches?/2 is exact-only — explicit schemes required, no defaults" do
    {_id, {claims, _sig}} = epoch_wire(["a.example"], ["https"], @ts)
    resolved = Schema.resolve(claims)
    epoch = %{id: "x", allow_hosts: resolved.allow_host, allow_schemes: resolved.allow_scheme}

    assert Policy.matches?(epoch, "https://a.example/x")
    refute Policy.matches?(epoch, "http://a.example/x")
    refute Policy.matches?(epoch, "https://sub.a.example/x")

    # zero allow_scheme pointers refuses all gated calls — symmetric with
    # the empty host list; no default schemes exist
    bare = %{id: "x", allow_hosts: ["a.example"], allow_schemes: []}
    refute Policy.matches?(bare, "https://a.example/x")

    assert {:refuse, "url_policy: scheme not allowed by the current epoch"} =
             Policy.check(bare, "https://a.example/x")
  end

  # ------------------------------------------------------------------- AC5

  test "AC5: two fresh boots over the identical seed sequence — byte-identical wires, call-derived timestamps" do
    ws = tmp_workspace()

    sequence = fn ->
      {e1_id, e1} = epoch_wire(["a.example"], ["https"], @ts)
      set = %{e1_id => e1}

      call = call_delta("https://a.example/c", @ts + 1)
      out1 = run(set, call, ws)
      set = absorb(set, out1)

      {e2_id, e2} = epoch_wire([], ["https"], @ts + 2, e1_id)
      set = Map.put(set, e2_id, e2)

      # the duplicate re-fire (ToolCallDuplicate) + the epoch-2 refusal
      out2 = run(set, call, ws)
      out3 = run(set, call_delta("https://a.example/c", @ts + 3), ws)
      {[call.claims.timestamp, @ts + 1, @ts + 3], out1 ++ out2 ++ out3}
    end

    {_ts_a, wires_a} = sequence.()
    {_ts_b, wires_b} = sequence.()

    # content-derived ids: the two boots emit byte-identical wires
    assert wires_a == wires_b
    assert Enum.map(wires_a, & &1["id"]) == Enum.map(wires_b, & &1["id"])

    # no wall-clock in the decision path: every emitted claim's ts equals
    # its call delta's claims.timestamp exactly
    call_ts = MapSet.new([@ts + 1, @ts + 3])

    for wire <- wires_a do
      {:ok, delta} = Store.verify(wire)
      assert MapSet.member?(call_ts, delta.claims.timestamp)
    end
  end
end
