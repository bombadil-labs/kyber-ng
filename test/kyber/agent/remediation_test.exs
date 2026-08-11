defmodule Kyber.Agent.RemediationTest do
  @moduledoc """
  T14h H2 (the settled coin-flip) — digest retraction is recursive-existential
  NO-ROLLBACK (`:none` until the next mint; the fallback-to-previous-head
  re-exposes the just-negated content) and the REMEDIATION RUNBOOK is
  WITNESSED on both halves: negating only the poisoned digest head is NOT
  sufficient — the next per-answer mint re-derives the same leaked line from
  the LIVE source delta; negating the SOURCE delta + the dead heads, THEN
  the re-mint derives clean. "Derives clean" requires the covered set to
  exclude negated sources for ALL five kinds (the liveness filter before
  line derivation — author-blind, M6).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Digest, Engine, Events, LlmHandler, MemoryPort, Prompt}
  alias Rhizomatic.Delta

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)
  @ts 1_700_000_000_000.0

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      send(state.reply_to, {:llm_request, JSON.decode!(body)})
      content = "stub answer"
      body = JSON.encode!(%{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}}]})
      {:ok, %{status: 200, body: body}}
    end
  end

  defp llm do
    {:ok, handler} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: self()}},
        model: "stub-model"
      )

    handler
  end

  defp start_store(initial \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp put_wire(store, wire) do
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp start_engine(store, opts \\ []) do
    test = self()

    {:ok, engine} =
      Engine.start_link(
        Keyword.merge(
          [
            name: nil,
            llm: llm(),
            store: fn -> Agent.get(store, & &1) end,
            sink: fn wire ->
              put_wire(store, wire)
              send(test, {:sink, wire})
              {:ok, :persisted}
            end
          ],
          opts
        )
      )

    engine
  end

  defp ingest_received(store, ts, msg_id, content) do
    {:ok, signed} = Kyber.Events.message_received(@human_seed, ts, msg_id, "chan-1", "session:s1", content)
    put_wire(store, Wire.envelope(signed))
  end

  defp request_inference(store, engine, prompt_delta) do
    builder =
      ContextBuilder.handler(
        seed: @agent_seed,
        store: fn -> Agent.get(store, & &1) end,
        memory: {MemoryPort.Stub, %{}}
      )

    [wire] = builder.([prompt_delta])
    request = put_wire(store, wire)
    assert Engine.handler(engine).([request]) == []
    request
  end

  defp sink_typed(type) do
    assert_receive {:sink, %{"id" => _} = wire}, 2_000
    {:ok, delta} = Store.verify(wire)

    case Schema.resolve(delta.claims) do
      %{type: ^type} = typed -> {typed, delta}
      _other -> sink_typed(type)
    end
  end

  defp raw_negation(target_id, opts \\ []) do
    seed = Keyword.get(opts, :seed, @human_seed)
    ts = Keyword.get(opts, :ts, @ts + 99)

    claims = %{
      timestamp: ts,
      author: Keys.author_for_seed(seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, sig} = Keys.sign(claims, seed)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp admit(store, {id, {claims, sig}}) do
    put_wire(store, Wire.envelope({claims, sig}))
    id
  end

  defp digest_heads(set) do
    for {_id, {claims, _sig}} <- set,
        match?(%{type: "StandingDigest"}, Schema.resolve(claims)),
        do: claims
  end

  # ------------------------------------------------------------ the runbook

  test "H2 runbook half 1: negating ONLY the digest head is NOT sufficient — the next per-answer mint re-derives the leaked line from the LIVE source" do
    store = start_store()
    engine = start_engine(store)

    # turn 1: the leaked secret ask rides the digest
    prompt1 = ingest_received(store, @ts, "msg-1", "the secret ask")
    request_inference(store, engine, prompt1)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {d1, d1_delta} = sink_typed("StandingDigest")
    assert d1.content =~ "the secret ask"
    head_id = d1_delta.id

    # negate ONLY the digest head — the trajectory is :none (no-rollback)
    admit(store, raw_negation(head_id))
    set = Agent.get(store, & &1)
    assert :none = Digest.head(set, "session:s1")

    # the NEXT answer (a new turn) re-mints: the source MessageReceived is
    # still LIVE, so the new derivation re-derives the leaked line — the
    # head-only negation re-leaks
    prompt2 = ingest_received(store, @ts + 10, "msg-2", "follow up")
    request_inference(store, engine, prompt2)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {d2, _} = sink_typed("StandingDigest")

    assert d2.content =~ "the secret ask"
    assert d2.content =~ "follow up"
    assert {:ok, content} = Digest.head(Agent.get(store, & &1), "session:s1")
    assert content =~ "the secret ask"
  end

  test "H2 runbook half 2: negate the SOURCE delta + the dead heads, THEN the re-mint derives clean" do
    store = start_store()
    engine = start_engine(store)

    # turn 1: the leaked line rides
    prompt1 = ingest_received(store, @ts, "msg-1", "the secret ask")
    request_inference(store, engine, prompt1)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {_d1, d1_delta} = sink_typed("StandingDigest")
    head_id = d1_delta.id

    # the RUNBOOK: negate the SOURCE delta (the MessageReceived whose text
    # leaked) AND the dead digest head
    source_id = prompt1.id
    admit(store, raw_negation(source_id))
    admit(store, raw_negation(head_id))

    # the NEXT answer re-mints CLEAN: the negated source produces no line
    prompt2 = ingest_received(store, @ts + 10, "msg-2", "follow up")
    request_inference(store, engine, prompt2)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {d2, _} = sink_typed("StandingDigest")

    assert d2.content =~ "follow up"
    refute d2.content =~ "the secret ask"
  end

  test "H2: a negated covered source produces no line for ALL five kinds — the liveness filter runs BEFORE line derivation" do
    store = start_store()
    session = "session:five"

    # one full tool turn
    add(store, Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "ask five"))
    {:ok, req} = Events.inference_requested(@agent_seed, @ts + 1, "m", session, "conv", "pr", [])
    req_id = Delta.id_hex(elem(req, 0))
    add(store, req)
    {:ok, call} = Events.tool_call(@agent_seed, @ts + 2, "fs.read", "{}", req_id)
    call_id = Delta.id_hex(elem(call, 0))
    add(store, call)
    {:ok, result} = Events.tool_result(@agent_seed, @ts + 3, call_id, "result five", "ok")
    add(store, result)
    {:ok, decision} = Events.gate_decision(@agent_seed, @ts + 4, call_id, "allow", "fs_policy")
    add(store, decision)
    {:ok, response} = Events.response_delta(@agent_seed, @ts + 5, req_id, 0.0, "answer five", [])
    add(store, response)

    set = Agent.get(store, & &1)
    %{content: before} = Digest.derive(set, session)
    assert before =~ "ask five"
    assert before =~ "done: fs.read"
    assert before =~ "decided: allow"
    assert before =~ "answer five"

    # negate EVERY covered source (all five kinds, author-blind)
    for {_id, {claims, _sig}} <- set,
        %{pointers: [%{role: role} | _]} = claims,
        role in ["received", "requestRef", "tool", "call", "decides"] do
      admit(store, raw_negation(_id))
    end

    set = Agent.get(store, & &1)
    %{content: cleaned} = Digest.derive(set, session)
    assert cleaned == ""
  end

  test "H2: restore = negate the negation — the source line rides again (recursive-existential)" do
    store = start_store()
    session = "session:restore"

    {:ok, {rec_claims, rec_sig}} =
      Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "the restored ask")

    rec_id = Delta.id_hex(rec_claims)
    put_wire(store, Wire.envelope({rec_claims, rec_sig}))

    neg_id = admit(store, raw_negation(rec_id))
    set = Agent.get(store, & &1)
    refute Digest.derive(set, session).content =~ "the restored ask"

    # restore: negate the live negation
    admit(store, raw_negation(neg_id, ts: @ts + 3))
    set = Agent.get(store, & &1)
    assert Digest.derive(set, session).content =~ "the restored ask"
  end

  test "L3: the raw window (conversation/2, retraction-blind) keeps the negated source's text — the runbook purges DERIVED views only" do
    store = start_store()
    session = "session:l3"

    {:ok, {rec_claims, rec_sig}} =
      Kyber.Events.message_received(@human_seed, @ts, "msg:1", "chan-1", session, "the raw text")

    rec_id = Delta.id_hex(rec_claims)
    put_wire(store, Wire.envelope({rec_claims, rec_sig}))
    admit(store, raw_negation(rec_id))

    set = Agent.get(store, & &1)

    # the digest derivation is clean
    refute Digest.derive(set, session).content =~ "the raw text"

    # the raw window still shows it (retraction-blind by its slice's design)
    turns = ContextBuilder.conversation(set, session)
    assert Enum.any?(turns, &(&1.content == "the raw text"))
  end

  defp add(store, {:ok, signed}) do
    put_wire(store, Wire.envelope(signed))
  end

  defp add(store, {claims, sig} = signed) when is_map(claims) do
    put_wire(store, Wire.envelope(signed))
  end
end
