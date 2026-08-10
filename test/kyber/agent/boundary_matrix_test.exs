defmodule Kyber.Agent.BoundaryMatrixTest do
  @moduledoc """
  T14d AC1 — the gate matrix: every Class A cell's outcome pinned and
  witnessed. The clause-table cells (A2-A8) keep their T14c legs; the open
  cells (A1, A4, A9-A11) get new legs; the folds (A12, A13, A11b) ride
  here. Fails-when-absent: deleting any clause-table row or matrix leg
  fails the suite.

  The matrix's pinned grammar (the T14d diff metric): the memory epoch arms
  match BEFORE args decode — `:none` and `{:error, :forked}` refuse with the
  EXISTING literals and NO ToolResult (the executor's `decide/8` emits only
  the GateDecision — reject, never repair); under a governing epoch,
  undecodable args make the policy layer ABSTAIN and the action's own
  validation answers; url degenerates refuse in scheme-then-host order;
  vacuous epochs refuse-all.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Action, Events, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @request_id String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0

  # the injected HTTP client — records every request; never a real service
  defmodule RecordingHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def get(url, _headers, state) do
      send(state.reply_to, {:http_get, url})
      {:ok, %{status: 200, body: "ok"}}
    end

    @impl true
    def post(url, _headers, _body, state) do
      send(state.reply_to, {:http_post, url})
      {:ok, %{status: 200, body: "ok"}}
    end
  end

  # ------------------------------------------------------------ scaffolding

  defp memory_epoch(allow_entities, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    supersedes = Keyword.get(opts, :supersedes)

    {:ok, {claims, sig}} = Events.memory_policy(@agent_seed, ts, allow_entities, supersedes)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp memory_entity(entity_id, content) do
    {:ok, {claims, sig}} = Events.memory_entity(@agent_seed, @ts, entity_id, content, [])
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp url_epoch(hosts, schemes, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)

    {:ok, {claims, sig}} = Events.policy(@agent_seed, ts, "url_policy", hosts, schemes)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp call_delta(tool, args, ts) do
    {:ok, signed} = Events.tool_call(@agent_seed, ts, tool, args, @request_id)
    {:ok, call} = Store.verify(Wire.envelope(signed))
    call
  end

  defp memory_handler(set) do
    ToolExecutor.handler(
      seed: @agent_seed,
      tools: ToolExecutor.memory_tools(fn -> set end),
      gate: Gate.new(default: :allow),
      store: fn -> set end
    )
  end

  defp url_handler(set) do
    ws = Path.join(System.tmp_dir!(), "kyber-t14d-matrix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    ToolExecutor.handler(
      seed: @agent_seed,
      tools: Action.registry(),
      gate: Gate.new(default: :allow),
      context: Action.context(workspace: ws, http: {RecordingHttp, %{reply_to: self()}}),
      store: fn -> set end
    )
  end

  defp resolve_wire(wire) do
    {:ok, delta} = Store.verify(wire)
    Schema.resolve(delta.claims)
  end

  defp assert_refusal(wire, policy, reason, epoch_pointer) do
    resolved = resolve_wire(wire)
    assert resolved.type == "GateDecision"
    assert resolved.verdict == "refuse"
    assert resolved.policy == policy
    assert resolved.reason == reason
    assert resolved.policy_epoch == epoch_pointer
  end

  # ------------------------------------------------------- the matrix legs

  # A1 — forked epoch × undecodable args: the epoch arms match BEFORE args
  # decode (tool_executor's pinned clause order) — refuse with the EXISTING
  # forked literal, NO ToolResult (D1; the spec's ":allow" column was defect
  # S2 — the fork×undecodable cell was an enumeration gap, never a behavior
  # gap).
  test "A1: forked epoch x undecodable args — refuse forked, args never examined" do
    {id_a, epoch_a} = memory_epoch(["e1"])
    {id_b, epoch_b} = memory_epoch(["e2"], ts: @ts + 1)
    handler = memory_handler(%{id_a => epoch_a, id_b => epoch_b})
    call = call_delta("memory.read", "not json", @ts + 2)

    assert [refusal_wire] = handler.([call])
    assert_refusal(refusal_wire, "memory_policy", "memory_policy: epoch forked (fail closed)", nil)
  end

  # A2 — forked epoch × valid args: refuse forked (the T14c leg, kept)
  test "A2: forked epoch x valid args — refuse forked" do
    {id_a, epoch_a} = memory_epoch(["e1"])
    {id_b, epoch_b} = memory_epoch(["e2"], ts: @ts + 1)
    handler = memory_handler(%{id_a => epoch_a, id_b => epoch_b})
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 2)

    assert [refusal_wire] = handler.([call])
    assert_refusal(refusal_wire, "memory_policy", "memory_policy: epoch forked (fail closed)", nil)
  end

  # A3 — ungoverned × valid args: refuse fail-closed (the memory family is
  # born fail-closed from birth; the URL family's fail-open default is
  # recorded debt — A13's tripwire)
  test "A3: ungoverned store x valid args — refuse ungoverned (fail closed)" do
    handler = memory_handler(%{})
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "memory_policy",
      "memory_policy: no governing epoch (fail closed)",
      nil
    )
  end

  # A4 — ungoverned × undecodable args: the `:none` row precedes args decode
  # — refuse ungoverned, args never examined (D2)
  test "A4: ungoverned store x undecodable args — refuse ungoverned, args never examined" do
    handler = memory_handler(%{})
    call = call_delta("memory.read", "not json", @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "memory_policy",
      "memory_policy: no governing epoch (fail closed)",
      nil
    )
  end

  # A5 — governed epoch × undecodable args: the policy layer ABSTAINS (the
  # action's own validation owns the cell) — the call runs, the run clause
  # answers "malformed action arguments: " <> args / "error"
  test "A5: governed epoch x undecodable args — policy abstains, action validation answers" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    handler = memory_handler(%{epoch_id => epoch})
    call = call_delta("memory.read", "not json", @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"
    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.status == "error"
    assert result.result == "malformed action arguments: not json"
  end

  # A6 — governed × entity allowed: :allow + the canon rides the ToolResult
  test "A6: governed epoch x allowed entity — allow + canon content" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    {mem_id, mem} = memory_entity("e1", "the oracle answer is 42")
    handler = memory_handler(%{epoch_id => epoch, mem_id => mem})
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    assert resolve_wire(gate_wire).verdict == "allow"
    result = resolve_wire(result_wire)
    assert result.status == "ok"
    assert result.result == "the oracle answer is 42"
  end

  # A7 — governed × entity refused: the pinned entity reason + epoch pointer
  test "A7: governed epoch x refused entity — entity reason with epoch pointer" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    {mem_id, mem} = memory_entity("e-secret", "classified")
    handler = memory_handler(%{epoch_id => epoch, mem_id => mem})
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e-secret"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "memory_policy",
      "memory_policy: entity not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
  end

  # A8 — epoch with zero allow_entities: refuse-all (unevolved epoch =
  # vacuous; no default allow-list exists)
  test "A8: zero allow_entities — refuse every read" do
    {epoch_id, epoch} = memory_epoch([])
    handler = memory_handler(%{epoch_id => epoch})
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "memory_policy",
      "memory_policy: entity not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
  end

  # A9 — url_policy degenerate inputs (D5): non-binary / absent "url" —
  # the policy ABSTAINS (extract_url is binary-guarded) and the ACTION
  # answers; no request is ever made
  test "A9: url null — policy abstains, the action answers refused, no request" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => nil}), @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    result = resolve_wire(result_wire)
    assert result.status == "refused"
    assert result.result == "refused: url must be a string"
    refute_received {:http_get, _}
  end

  test "A9: url number — policy abstains, the action answers refused, no request" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => 42}), @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    result = resolve_wire(result_wire)
    assert result.status == "refused"
    assert result.result == "refused: url must be a string"
    refute_received {:http_get, _}
  end

  test "A9: missing url key — policy abstains, the action answers error, no request" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{}), @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    result = resolve_wire(result_wire)
    assert result.status == "error"
    assert result.result == "http.get: a \"url\" string argument is required"
    refute_received {:http_get, _}
  end

  test "A9: non-JSON args — policy abstains, malformed action arguments, no request" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", "not json", @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    result = resolve_wire(result_wire)
    assert result.status == "error"
    assert result.result == "malformed action arguments: not json"
    refute_received {:http_get, _}
  end

  # A9b — binary-but-malformed URLs: refuse in scheme-then-host order.
  # URI.parse("https://") yields host "" (NEVER nil — substrate-verified),
  # which fails the host allow-list
  test "A9: scheme-then-host — no scheme refuses at the scheme clause" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "allowed.example/no-scheme"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "url_policy",
      "url_policy: scheme not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
    refute_received {:http_get, _}
  end

  test "A9: scheme-then-host — https:// (empty host, never nil) refuses at the host clause" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "url_policy",
      "url_policy: host not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
    refute_received {:http_get, _}
  end

  # A10 — vacuous epochs (D5c): empty allow_schemes refuses all at the
  # scheme clause; empty allow_hosts at the host clause — no default exists,
  # refuse-all stands
  test "A10: empty allow_schemes — every scheme refuses at the scheme clause" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], [])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://allowed.example/x"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "url_policy",
      "url_policy: scheme not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
    refute_received {:http_get, _}
  end

  test "A10: empty allow_hosts — every host refuses at the host clause" do
    {epoch_id, epoch} = url_epoch([], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://allowed.example/x"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "url_policy",
      "url_policy: host not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
    refute_received {:http_get, _}
  end

  # A11 — scheme/host case: the host compare downcases the URL (DNS-class
  # equivalence, the T14b pin); the scheme compare is EXACT (URI.parse
  # downcases the scheme, and the stored allow_scheme values are NOT
  # constructor-downcased)
  test "A11: mixed-case host matches the downcased allow_host entry" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://ALLOWED.Example/x"}), @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    assert resolve_wire(result_wire).status == "ok"
    assert_received {:http_get, "https://ALLOWED.Example/x"}
  end

  # A11b (fold P1) — scheme-case ASYMMETRY: the epoch's allow_scheme value
  # is stored verbatim ("HTTPS" is never downcased — the downcase pin is
  # host-specific), so a stored "HTTPS" refuses ALL https calls (fail-closed
  # asymmetry, recorded)
  test "A11b: stored scheme-case asymmetry — allow_scheme HTTPS refuses all https" do
    {epoch_id, epoch} = url_epoch(["allowed.example"], ["HTTPS"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://allowed.example/x"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "url_policy",
      "url_policy: scheme not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
    refute_received {:http_get, _}
  end

  # A12 (fold P2) — entity-id case sensitivity: NO downcase on entity ids
  # (entity ids are content-derived; case is not a DNS-class equivalence) —
  # allow_entities ["Alice"] refuses "alice" and allows "Alice"
  test "A12: entity ids are case-sensitive — Alice allows, alice refuses" do
    {epoch_id, epoch} = memory_epoch(["Alice"])
    {mem_id, mem} = memory_entity("Alice", "case-sensitive canon")
    handler = memory_handler(%{epoch_id => epoch, mem_id => mem})

    allowed = call_delta("memory.read", JSON.encode!(%{"entity" => "Alice"}), @ts + 1)
    assert [gate_wire, result_wire] = handler.([allowed])
    assert resolve_wire(gate_wire).verdict == "allow"
    assert resolve_wire(result_wire).result == "case-sensitive canon"

    refused = call_delta("memory.read", JSON.encode!(%{"entity" => "alice"}), @ts + 2)
    assert [refusal_wire] = handler.([refused])
    assert_refusal(
      refusal_wire,
      "memory_policy",
      "memory_policy: entity not allowed by the current epoch",
      {:delta, epoch_id, "under"}
    )
  end

  # A13 (fold P3) — the url ungoverned fail-open hole, CLOSED by T14e: with
  # no url_policy claim the call is REFUSED with the url_ungoverned reason —
  # never executed (the T14d tripwire's purpose is served: the deferred
  # governance-default slice consciously flipped it HERE; the `:none -> :allow`
  # fail-open row no longer exists). Reverting the closure fails this leg:
  # the call would execute and `refute_received` trips.
  test "A13: url ungoverned fails CLOSED — no url_policy claim, refused, no request" do
    handler = url_handler(%{})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://anywhere.example/"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    assert_refusal(
      refusal_wire,
      "url_policy",
      "url_policy: no governing epoch (fail closed)",
      nil
    )
    refute_received {:http_get, _}
  end

  # A13b (T14e blast-radius leg) — the closure must not break GOVERNED url
  # calls: with a governing url_policy claim the SAME call still executes
  test "A13b: governed url calls still execute — the closure's blast radius is zero" do
    {epoch_id, epoch} = url_epoch(["anywhere.example"], ["https"])
    handler = url_handler(%{epoch_id => epoch})
    call = call_delta("http.get", JSON.encode!(%{"url" => "https://anywhere.example/"}), @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    assert resolve_wire(result_wire).status == "ok"
    assert_received {:http_get, "https://anywhere.example/"}
  end
end
