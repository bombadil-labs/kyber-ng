defmodule Kyber.Agent.MemoryGateTest do
  @moduledoc """
  T14c AC2 — the memory-read permission seam: a memory read routes through
  the gate (the third executor layer, `memory_policy`, chained AFTER
  `url_policy`, before execute) — an allowed read returns the memory +
  records a permission GateDecision; a refused read returns a refusal
  routed through "decides" (ONE GateDecision, NO ToolResult — reject,
  never repair) and NO memory content leaves the store: the high-entropy
  sentinel substring scan (P3's absorbed leg, extended by D4's ruling)
  covers every admitted claim AND the transcript AND `PromptAssembled`
  content — scoped: "refused entity" means refused UNDER a governing epoch
  (excluded/forked); the ungoverned gather is the recorded legacy hole,
  asserted separately as behavior.

  The gather legs (SYNTH-NEW, D4) live here too: `Prompt.assemble/4` is the
  SECOND gated surface, gated by a call-less mechanism (omit-from-prompt,
  no GateDecision minted), with id->entity resolution by CHAIN MEMBERSHIP
  (`Memory.resolve_set/2`) — a canon head that is a `MemoryEdited` carries
  no direct entity pointer, so a direct-pointer reading fails the leg.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Harness, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Events, LlmHandler, Memory, Prompt, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @human_seed String.duplicate("cd", 32)
  @request_id String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0

  # the high-entropy leak sentinel — distinct from every entity id so the
  # scans are meaningful
  @sentinel "SENTINEL-9f3ac1e7b2d4-LEAK"

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

  defp memory_edited(edited_id, content, reason \\ "human_edit") do
    {:ok, {claims, sig}} = Events.memory_edited(@agent_seed, @ts + 1, edited_id, content, reason)
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
      tools: tools || ToolExecutor.memory_tools(fn -> set end),
      gate: Gate.new(default: :allow),
      store: fn -> set end
    )
  end

  defp resolve_wire(wire) do
    {:ok, delta} = Store.verify(wire)
    Schema.resolve(delta.claims)
  end

  # ------------------------------------------------------------ tool legs

  test "AC2 allow: an allowed read returns the canon + records the permission GateDecision (real content flow)" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    {mem_id, mem} = memory_entity("e1", "the cap is a lens: " <> @sentinel)
    set = %{epoch_id => epoch, mem_id => mem}
    handler = handler_with(set)
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 1)

    assert [gate_wire, result_wire] = handler.([call])
    decision = resolve_wire(gate_wire)
    assert decision.type == "GateDecision"
    assert decision.verdict == "allow"
    # the silent-on-allow rule: the permission gate's own allow emission IS
    # the AC2 permission GateDecision
    assert decision.decides == {:delta, call.id, "decided"}

    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.status == "ok"
    # REAL content flow — the ToolResult content equals the resolved canon
    # (kills the deny-all-placebo)
    assert result.result == "the cap is a lens: " <> @sentinel
  end

  test "AC2 refuse: an excluded entity — memory_policy refusal, pinned reason + epoch pointer, NO ToolResult, no leak" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    {mem_id, mem} = memory_entity("e-secret", "classified: " <> @sentinel)
    set = %{epoch_id => epoch, mem_id => mem}
    handler = handler_with(set)
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e-secret"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "memory_policy"
    assert refusal.reason == "memory_policy: entity not allowed by the current epoch"
    assert refusal.policy_epoch == {:delta, epoch_id, "under"}

    # NO ToolResult — nothing was read; the sentinel never leaves the store
    refute_received {:memory_retriever_fired, _}
    set_after = absorb(set, [refusal_wire])
    scan_claims(set_after, [epoch_id, mem_id])
  end

  test "AC2 refuse: a zero-allow_entity epoch refuses ALL gated reads" do
    {epoch_id, epoch} = memory_epoch([])
    {mem_id, mem} = memory_entity("e1", "classified: " <> @sentinel)
    set = %{epoch_id => epoch, mem_id => mem}
    handler = handler_with(set)
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "memory_policy"
    assert refusal.reason == "memory_policy: entity not allowed by the current epoch"
    assert refusal.policy_epoch == {:delta, epoch_id, "under"}
  end

  test "AC2 refuse: UNGOVERNED store — the fail-closed default; sentinel absent from the gated call's artifacts" do
    {mem_id, mem} = memory_entity("e-secret", "classified: " <> @sentinel)

    # the triggering request carries ZERO sentinel memoryPointers — the
    # sentinel never enters this leg's store flow
    {:ok, {req_claims, req_sig}} =
      Events.inference_requested(
        @agent_seed,
        @ts,
        "stub-model",
        "session:s1",
        "conv-ref",
        "prompt-ref",
        []
      )

    req_id = Delta.id_hex(req_claims)
    set = %{mem_id => mem, req_id => {req_claims, req_sig}}
    handler = handler_with(set)
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e-secret"}), @ts + 1)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "memory_policy"
    assert refusal.reason == "memory_policy: no governing epoch (fail closed)"
    assert refusal.policy_epoch == nil

    # zero sentinel memoryPointers on the triggering request
    refute inspect(req_claims) =~ @sentinel

    # the sentinel is absent from the gated call's artifacts — the refusal
    # wire (no ToolResult exists to carry content) and the request
    {:ok, refusal_json} = Wire.encode(refusal_wire)
    refute refusal_json =~ @sentinel
  end

  test "AC2 refuse: FORKED memory epochs — fail closed, no epoch pointer" do
    {id_a, epoch_a} = memory_epoch(["e1"])
    {id_b, epoch_b} = memory_epoch(["e2"], ts: @ts + 1)
    set = %{id_a => epoch_a, id_b => epoch_b}
    handler = handler_with(set)
    call = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 2)

    assert [refusal_wire] = handler.([call])
    refusal = resolve_wire(refusal_wire)
    assert refusal.type == "GateDecision"
    assert refusal.verdict == "refuse"
    assert refusal.policy == "memory_policy"
    assert refusal.reason == "memory_policy: epoch forked (fail closed)"
    assert refusal.policy_epoch == nil
  end

  test "AC2: undecodable args — the policy layer abstains, the action's own validation answers" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    set = %{epoch_id => epoch}
    handler = handler_with(set)
    call = call_delta("memory.read", "not json", @ts + 1)

    assert [_gate_wire, result_wire] = handler.([call])
    result = resolve_wire(result_wire)
    assert result.type == "ToolResult"
    assert result.status != "ok"
  end

  test "AC2: gate-before-retrieval — the recording retriever NEVER fires, refused or allowed (resolution is store-derived)" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    {mem_id, mem} = memory_entity("e1", "real canon content")
    set = %{epoch_id => epoch, mem_id => mem}

    recorder = fn args ->
      send(self(), {:memory_retriever_fired, args})
      "RETRIEVER-" <> args
    end

    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: %{"memory.read" => recorder},
        gate: Gate.new(default: :allow),
        store: fn -> set end
      )

    # a refused read never reaches the retrieval surface
    refused = call_delta("memory.read", JSON.encode!(%{"entity" => "e-other"}), @ts + 1)
    assert [_refusal_wire] = handler.([refused])
    refute_received {:memory_retriever_fired, _}

    # an allowed read resolves from the STORE (the dedicated run clause),
    # never the registry entry
    allowed = call_delta("memory.read", JSON.encode!(%{"entity" => "e1"}), @ts + 2)
    assert [_gate_wire, result_wire] = handler.([allowed])
    result = resolve_wire(result_wire)
    assert result.result == "real canon content"
    refute_received {:memory_retriever_fired, _}
  end

  # ----------------------------------------------------------- gather legs

  test "AC2 gather (governed): the excluded entity's canon head (a MemoryEdited, no entity pointer) is omitted from the assembled prompt" do
    {epoch_id, epoch} = memory_epoch(["e1"])
    {e1_id, e1} = memory_entity("e1", "allowed note")
    {e2_id, e2} = memory_entity("e2", "classified: " <> @sentinel)
    {edit_id, edit} = memory_edited(e2_id, "edited classified: " <> @sentinel)
    set = %{epoch_id => epoch, e1_id => e1, e2_id => e2, edit_id => edit}

    # the canon head IS the MemoryEdited — it carries NO direct entity
    # pointer, so a direct-pointer id->entity reading fails this leg;
    # chain membership via Memory.resolve_set/2 must resolve it
    {edit_claims, _sig} = edit
    refute Enum.any?(edit_claims.pointers, &(&1.role == "entity"))
    %{entity: "e2", head: ^edit_id} = Memory.canon(set, "e2")

    messages = Prompt.assemble(set, "session:s1", [e1_id, edit_id], 8)
    canonical = Prompt.canonical(messages)

    # the excluded note is omitted; the allowed note rides
    refute canonical =~ @sentinel
    assert canonical =~ "allowed note"

    # the sentinel scan of the PromptAssembled claim itself stays clean
    {:ok, pa_signed} =
      Events.prompt_assembled(@agent_seed, @ts, "req-gov", "session:s1", canonical)

    {:ok, pa_json} = Wire.encode(Wire.envelope(pa_signed))
    refute pa_json =~ @sentinel
  end

  test "AC2 gather (forked): NO memory notes ride the assembled prompt — fail closed on fork" do
    {id_a, epoch_a} = memory_epoch(["e1"])
    {id_b, epoch_b} = memory_epoch(["e2"], ts: @ts + 1)
    {e1_id, e1} = memory_entity("e1", "note one " <> @sentinel)
    {e2_id, e2} = memory_entity("e2", "note two " <> @sentinel)
    set = %{id_a => epoch_a, id_b => epoch_b, e1_id => e1, e2_id => e2}

    messages = Prompt.assemble(set, "session:s1", [e1_id, e2_id], 8)
    canonical = Prompt.canonical(messages)
    refute canonical =~ @sentinel
    refute canonical =~ "Memory:"
  end

  test "AC2 gather (ungoverned): the recorded legacy hole as behavior — sentinel-PRESENT in the assembled prompt" do
    {e1_id, e1} = memory_entity("e1", "note " <> @sentinel)
    set = %{e1_id => e1}

    messages = Prompt.assemble(set, "session:s1", [e1_id], 8)
    canonical = Prompt.canonical(messages)
    assert canonical =~ @sentinel
  end

  # --------------------------------------------- the AC2 reactor companion

  # the scripted LLM seam for the companion boot: the FIRST chat asks for
  # memory.read e-secret (a refused read); after the refusal loops back the
  # turn completes with a plain answer — the routing-to-engine proof
  defmodule ScriptedToolLlm do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      send(state.reply_to, {:llm_request_body, body})
      decoded = JSON.decode!(body)

      response =
        if Enum.any?(decoded["messages"], &match?(%{"role" => "tool"}, &1)) do
          JSON.encode!(%{
            "choices" => [
              %{"message" => %{"role" => "assistant", "content" => "refusal handled"}}
            ]
          })
        else
          JSON.encode!(%{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "tool_calls" => [
                    %{
                      "id" => "call_scripted_memory",
                      "function" => %{
                        "name" => "memory_read",
                        "arguments" => JSON.encode!(%{"entity" => "e-secret"})
                      }
                    }
                  ]
                }
              }
            ]
          })
        end

      {:ok, %{status: 200, body: response}}
    end
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  # bounded sleep-free store polling (the no-sleep idiom: a timeout-only
  # receive never matches mailbox messages)
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

  describe "AC2 reactor companion" do
    setup do
      config_log_path = Application.get_env(:kyber, :log_path)
      uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
      key_dir = Path.join(System.tmp_dir!(), "kyber-t14c-memgate-keyring-#{uniq}")
      log_dir = Path.join(System.tmp_dir!(), "kyber-t14c-memgate-log-#{uniq}")
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

    test "AC2 companion: a refused memory.read through the reactor — the memory_policy refusal is store-witnessed, routed to the engine (the turn completes), NO ToolResult, no leak",
         ctx do
      # the governing memory epoch + the sentinel memory, persisted BEFORE
      # the turn
      {:ok, {epoch_claims, epoch_sig}} = Events.memory_policy(@agent_seed, @ts, ["e1"])
      epoch_id = Delta.id_hex(epoch_claims)
      :ok = DurableStore.append(Wire.envelope({epoch_claims, epoch_sig}))

      {:ok, {mem_claims, mem_sig}} =
        Events.memory_entity(@agent_seed, @ts, "e-secret", "classified: " <> @sentinel, [])

      mem_id = Delta.id_hex(mem_claims)
      :ok = DurableStore.append(Wire.envelope({mem_claims, mem_sig}))

      {:ok, llm} =
        LlmHandler.new(
          seed: ctx.agent_seed,
          api_key: "stub-key",
          http: {ScriptedToolLlm, %{reply_to: self()}},
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
            tools: ToolExecutor.memory_tools(fn -> DurableStore.set() end),
            gate: Gate.new(allow: ["memory.read"])
          ]
        )

      {:ok, _received_id} =
        Harness.ingest(
          %{
            "message_id" => "message:memgate:companion",
            "channel_id" => "channel:reactor",
            "session_id" => "session:reactor",
            "content" => "read the secret memory and report it",
            "ts" => @ts + 2
          },
          ctx.key_dir
        )

      # the scripted model's memory.read call — the call is a real
      # ToolCall delta, routed through the real executor
      found =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(%{type: "ToolCall", tool: {:entity, "memory.read", _}}, Schema.resolve(claims))
        end)

      assert found != nil, "the scripted memory.read ToolCall never landed"
      {call_id, {call_claims, _sig}} = found

      # the refusal decision for THIS call — store-witnessed through the
      # reactor's emission path
      refusal =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(
            %{type: "GateDecision", decides: {:delta, ^call_id, _}},
            Schema.resolve(claims)
          )
        end)

      assert refusal != nil, "no GateDecision for the memory.read call reached the durable store"
      {_gd_id, {gd_claims, _sig}} = refusal
      typed = Schema.resolve(gd_claims)
      assert typed.verdict == "refuse"
      assert typed.policy == "memory_policy"
      assert typed.reason == "memory_policy: entity not allowed by the current epoch"
      assert typed.policy_epoch == {:delta, epoch_id, "under"}
      assert gd_claims.timestamp == call_claims.timestamp

      # NO ToolResult for the refused call — the read never happened
      refute Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               match?(%{type: "ToolResult", call: {:delta, ^call_id, _}}, Schema.resolve(claims))
             end)

      # the routing-to-engine assert: the refusal rode "decides" back into
      # the engine and the turn COMPLETED (a ResponseDelta exists) — the
      # closed refusal loop, hosted
      answered =
        poll_store(fn {_id, {claims, _sig}} ->
          match?(%{type: "ResponseDelta"}, Schema.resolve(claims))
        end)

      assert answered != nil, "the refused turn never completed through the engine"

      # the sentinel never left the store: every claim the leg admitted
      # (InferenceRequested, PromptAssembled, ToolCall, GateDecision,
      # ResponseDelta, MessageSent) is sentinel-free — only the seeded
      # memory claim carries it
      scan_claims(DurableStore.set(), [epoch_id, mem_id])

      # the transcript is sentinel-free too
      assert_receive {:llm_request_body, first_body}, 2_000
      assert_receive {:llm_request_body, second_body}, 2_000
      refute first_body =~ @sentinel
      refute second_body =~ @sentinel
    end
  end

  # -------------------------------------------------------------- machinery

  defp absorb(set, wires) do
    Enum.reduce(wires, set, fn wire, s ->
      {:ok, delta} = Store.verify(wire)
      Map.put(s, delta.id, {delta.claims, wire["sig"]})
    end)
  end

  # the sentinel substring scan: every claim EXCEPT the named seeds (the
  # seeded memory claim IS the sentinel's source, never a leak) must be
  # sentinel-free
  defp scan_claims(set, seed_ids) do
    Enum.each(set, fn {id, {claims, _sig}} ->
      if id not in seed_ids do
        refute inspect(claims) =~ @sentinel, "sentinel leaked into claim #{id}"
      end
    end)
  end
end
