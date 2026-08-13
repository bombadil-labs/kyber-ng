defmodule Kyber.Agent.PolicyUrlGateTest do
  @moduledoc """
  T14b AC1 — the URL policy gate in the executor's fresh-decide branch:
  a policy claim in the store gates `http.get`/`http.post` AFTER the
  permission gate allows; an allowed URL executes (exactly one recorded
  request), a refused URL yields a `url_policy` refusal GateDecision
  (verdict `refuse`, pinned reason, `policy_epoch` pointer) and the
  request is never made — asserted, not assumed.

  The reactor companion (H2) is store-side: the refusal is witnessed as a
  persisted claim in the durable store, THROUGH the reactor's dispatch —
  the dispatch probe is a routing signal only, never the witness.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Events, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Action, LlmHandler, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @human_seed String.duplicate("cd", 32)
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
    def post(url, _headers, body, state) do
      send(state.reply_to, {:http_post, url, body})
      {:ok, %{status: 200, body: "ok"}}
    end
  end

  defp tmp_workspace do
    ws = Path.join(System.tmp_dir!(), "kyber-t14b-urlgate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    ws
  end

  defp seed_epoch(hosts, schemes, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    supersedes = Keyword.get(opts, :supersedes)

    {:ok, {claims, sig}} =
      AgentEvents.policy(@agent_seed, ts, "url_policy", hosts, schemes, supersedes)

    {Delta.id_hex(claims), {claims, sig}}
  end

  defp handler_with(store_set) do
    ws = tmp_workspace()
    context = Action.context(workspace: ws, http: {RecordingHttp, %{reply_to: self()}})

    ToolExecutor.handler(
      seed: @agent_seed,
      tools: Action.registry(),
      gate: Gate.new(default: :allow),
      context: context,
      store: fn -> store_set end
    )
  end

  defp call_delta(tool, url, ts) do
    {:ok, signed} =
      AgentEvents.tool_call(@agent_seed, ts, tool, JSON.encode!(%{"url" => url}), @request_id)

    {:ok, call} = Store.verify(Wire.envelope(signed))
    call
  end

  # ------------------------------------------------------------------ tests

  test "AC1: an allowed URL executes — exactly one recorded request, allow decision + ToolResult" do
    {epoch_id, policy} = seed_epoch(["allowed.example"], ["https"])
    handler = handler_with(%{epoch_id => policy})
    call = call_delta("http.get", "https://allowed.example/x", @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    {:ok, decision} = Store.verify(gate_wire)
    assert %{type: "GateDecision", verdict: "allow"} = Schema.resolve(decision.claims)
    {:ok, result} = Store.verify(result_wire)
    assert %{type: "ToolResult", status: "ok"} = Schema.resolve(result.claims)

    assert_received {:http_get, "https://allowed.example/x"}
    refute_received {:http_get, _}
  end

  test "AC1: a refused host — url_policy refusal with policy_epoch, NO ToolResult, NO request" do
    {epoch_id, policy} = seed_epoch(["allowed.example"], ["https"])
    handler = handler_with(%{epoch_id => policy})
    call = call_delta("http.get", "https://denied.example/", @ts + 1)

    assert [refusal_wire] = handler.([call])
    {:ok, refusal} = Store.verify(refusal_wire)
    resolved = Schema.resolve(refusal.claims)
    assert resolved.type == "GateDecision"
    assert resolved.verdict == "refuse"
    assert resolved.policy == "url_policy"
    assert resolved.reason == "url_policy: host not allowed by the current epoch"
    assert resolved.policy_epoch == {:delta, epoch_id, "under"}

    refute_received {:http_get, _}
  end

  test "AC1: a refused scheme — the scheme check runs before the host check" do
    {epoch_id, policy} = seed_epoch(["allowed.example"], ["https"])
    handler = handler_with(%{epoch_id => policy})
    call = call_delta("http.get", "http://allowed.example/plain", @ts + 1)

    assert [refusal_wire] = handler.([call])
    {:ok, refusal} = Store.verify(refusal_wire)
    resolved = Schema.resolve(refusal.claims)
    assert resolved.verdict == "refuse"
    assert resolved.policy == "url_policy"
    assert resolved.reason == "url_policy: scheme not allowed by the current epoch"
    assert resolved.policy_epoch == {:delta, epoch_id, "under"}

    refute_received {:http_get, _}
  end

  test "AC1: mixed-case host in the URL matches the downcased allow_host entry" do
    {epoch_id, policy} = seed_epoch(["allowed.example"], ["https"])
    handler = handler_with(%{epoch_id => policy})
    call = call_delta("http.get", "https://ALLOWED.Example/x", @ts + 1)

    assert [_gate_wire, _result_wire] = handler.([call])
    assert_received {:http_get, "https://ALLOWED.Example/x"}
  end

  test "AC1: no policy claim in the store — ungoverned, the call is REFUSED (T14e closes the hole)" do
    handler = handler_with(%{})
    call = call_delta("http.get", "https://anywhere.example/", @ts + 1)

    assert [refusal_wire] = handler.([call])
    {:ok, refusal} = Store.verify(refusal_wire)
    resolved = Schema.resolve(refusal.claims)
    assert resolved.type == "GateDecision"
    assert resolved.verdict == "refuse"
    assert resolved.policy == "url_policy"
    assert resolved.reason == "url_policy: no governing epoch (fail closed)"
    assert resolved.policy_epoch == nil

    refute_received {:http_get, _}
  end

  test "AC1: a forked epoch refuses all gated calls — fail closed" do
    {id_a, policy_a} = seed_epoch(["allowed.example"], ["https"])
    {id_b, policy_b} = seed_epoch(["other.example"], ["https"], ts: @ts + 1)
    handler = handler_with(%{id_a => policy_a, id_b => policy_b})
    call = call_delta("http.get", "https://allowed.example/x", @ts + 2)

    assert [refusal_wire] = handler.([call])
    {:ok, refusal} = Store.verify(refusal_wire)
    resolved = Schema.resolve(refusal.claims)
    assert resolved.verdict == "refuse"
    assert resolved.policy == "url_policy"
    assert resolved.reason == "url_policy: epoch forked (fail closed)"

    refute_received {:http_get, _}
  end

  test "AC1: an ungated tool is untouched by the policy layer" do
    {epoch_id, policy} = seed_epoch(["allowed.example"], ["https"])
    ws = tmp_workspace()
    File.write!(Path.join(ws, "notes.txt"), "inside")
    context = Action.context(workspace: ws, http: {RecordingHttp, %{reply_to: self()}})

    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: Action.registry(),
        gate: Gate.new(default: :allow),
        context: context,
        store: fn -> %{epoch_id => policy} end
      )

    {:ok, signed} =
      AgentEvents.tool_call(
        @agent_seed,
        @ts + 1,
        "fs.read",
        JSON.encode!(%{"path" => "notes.txt"}),
        @request_id
      )

    {:ok, call} = Store.verify(Wire.envelope(signed))
    assert [_gate_wire, result_wire] = handler.([call])
    {:ok, result} = Store.verify(result_wire)
    assert %{type: "ToolResult", status: "ok"} = Schema.resolve(result.claims)
  end

  test "U1: the Httpc adapter never follows redirects — both option lists carry autoredirect: false (static witness)" do
    # the deterministic stub never redirects, so the U1 witness is the
    # option list itself, asserted statically: a 3xx is a terminal
    # ToolResult and a followed redirect would be an ungated second request
    source = File.read!("lib/kyber/agent/http_client.ex")

    option_lists =
      Regex.scan(~r/http_options = \[(.*?)\]/s, source, capture: :all_but_first)

    assert length(option_lists) == 2

    for [options] <- option_lists do
      assert options =~ "autoredirect: false"
    end
  end

  test "AC1: undecodable args — the policy layer abstains, the action's own validation answers" do
    {epoch_id, policy} = seed_epoch(["allowed.example"], ["https"])
    handler = handler_with(%{epoch_id => policy})

    {:ok, signed} =
      AgentEvents.tool_call(@agent_seed, @ts + 1, "http.get", "not json", @request_id)

    {:ok, call} = Store.verify(Wire.envelope(signed))
    assert [_gate_wire, result_wire] = handler.([call])
    {:ok, result} = Store.verify(result_wire)
    resolved = Schema.resolve(result.claims)
    assert resolved.type == "ToolResult"
    assert resolved.status != "ok"

    refute_received {:http_get, _}
  end

  # --------------------------------------- the AC1 reactor companion (H2)

  # the LLM-seam stub for the companion boot: a deterministic content-only
  # answer — no tool_calls, so the engine never plans a call of its own;
  # the seeded ToolCall below is the only one in the run
  defmodule StubLlmHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, _state) do
      body = JSON.encode!(%{"choices" => [%{"message" => %{"content" => "stub ok"}}]})
      {:ok, %{status: 200, body: body}}
    end
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  # bounded sleep-free store polling (the reactor_test idiom: a timeout-only
  # receive never matches mailbox messages, so it cannot swallow the
  # recorder's {:http_get, _} evidence)
  defp poll_store(pred, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Enum.find(DurableStore.set(), pred) do
        nil ->
          receive do
          after
            25 -> :timeout
          end

          {:cont, nil}

        found ->
          {:halt, found}
      end
    end)
  end

  describe "AC1 reactor companion" do
    setup do
      config_log_path = Application.get_env(:kyber, :log_path)
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t14b-companion-keyring-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t14b-companion-log-#{uniq}")
      File.mkdir_p!(key_dir)
      File.mkdir_p!(log_dir)
      :ok = Keys.import_human_seed(@human_seed, key_dir)
      {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

      stop_app()
      Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
      {:ok, _} = Application.ensure_all_started(:kyber)

      on_exit(fn ->
        Daemon.stop()
        stop_app()
        Application.put_env(:kyber, :log_path, config_log_path)
        File.rm_rf(key_dir)
        File.rm_rf(log_dir)
      end)

      {:ok, key_dir: key_dir, agent_seed: agent_seed}
    end

    test "AC1 companion: the url_policy refusal is store-witnessed THROUGH the reactor — no ToolResult, no request",
         ctx do
      ws = tmp_workspace()

      # the H2 contradiction, recorded: the pinned `engine: :none` +
      # permitting-gate topology is unbuildable under the bounded edits —
      # `executor_for(seed, :none)` hard-codes the deny-all default gate and
      # daemon.ex (ZERO-EDIT) threads no gate. The executor's gate/tools/
      # context reach the reactor ONLY through the engine keyword list, so
      # the companion boots a stub-LLM engine (deterministic: the LLM seam
      # is StubLlmHttp, never a network) — a test-internal deviation.
      {:ok, llm} =
        LlmHandler.new(
          seed: ctx.agent_seed,
          api_key: "stub-key",
          http: {StubLlmHttp, nil},
          model: "stub-model"
        )

      {:ok, _pid} =
        Daemon.boot(
          keyring_dir: ctx.key_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          budget_cap: 32,
          test_pid: self(),
          engine: [
            llm: llm,
            tools: Action.registry(),
            gate: Gate.new(allow: ["http.get", "http.post"]),
            context: Action.context(workspace: ws, http: {RecordingHttp, %{reply_to: self()}})
          ]
        )

      # the ancestry chain (H2): received → InferenceRequested → ToolCall,
      # each appended and routed through the reactor — never a bare call
      {:ok, received_signed} =
        Events.message_received(
          @human_seed,
          @ts,
          "message:policy:companion",
          "channel:reactor",
          "session:reactor",
          "companion ancestry root"
        )

      received_wire = Wire.envelope(received_signed)
      received_id = received_wire["id"]
      assert :ok = DurableStore.append(received_wire)
      assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

      # the policy epoch lands in the DURABLE store before the gated call
      {:ok, {epoch_claims, epoch_sig}} =
        AgentEvents.policy(ctx.agent_seed, @ts + 1, "url_policy", ["allowed.example"], ["https"])

      epoch_id = Delta.id_hex(epoch_claims)
      assert :ok = DurableStore.append(Wire.envelope({epoch_claims, epoch_sig}))

      {:ok, ir_signed} =
        AgentEvents.inference_requested(
          ctx.agent_seed,
          @ts + 2,
          "stub-model",
          "session:reactor",
          received_id,
          received_id,
          []
        )

      ir_wire = Wire.envelope(ir_signed)
      ir_id = ir_wire["id"]
      assert :ok = DurableStore.append(ir_wire)
      assert_receive {:reactor, {:dispatch, "promptRef", ^ir_id}}, 2_000

      {:ok, call_signed} =
        AgentEvents.tool_call(
          ctx.agent_seed,
          @ts + 3,
          "http.get",
          JSON.encode!(%{"url" => "https://denied.example/"}),
          ir_id
        )

      call_wire = Wire.envelope(call_signed)
      call_id = call_wire["id"]
      assert :ok = DurableStore.append(call_wire)

      # the dispatch probe is a ROUTING signal only (H2) — the witness is
      # the persisted claim below
      assert_receive {:reactor, {:dispatch, "tool", ^call_id}}, 2_000

      # store-side witness: the url_policy refusal GateDecision pinned to
      # THIS call, persisted through the reactor's emission path
      found =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(
            %{pointers: [%{role: "decides", target: {:delta, ^call_id, _}} | _]},
            claims
          )
        end)

      assert found != nil, "no GateDecision for the seeded call reached the durable store"
      {_gd_id, {gd_claims, _sig}} = found
      typed = Schema.resolve(gd_claims)
      assert typed.type == "GateDecision"
      assert typed.verdict == "refuse"
      assert typed.policy == "url_policy"
      assert typed.reason == "url_policy: host not allowed by the current epoch"
      assert typed.policy_epoch == {:delta, epoch_id, "under"}

      # no ToolResult for the refused call, anywhere in the store
      refute Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               match?(
                 %{type: "ToolResult", call: {:delta, ^call_id, _}},
                 Schema.resolve(claims)
               )
             end)

      # and the request was never made — asserted, not assumed
      refute_received {:http_get, _}
    end
  end
end
