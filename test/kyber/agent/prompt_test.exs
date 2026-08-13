defmodule Kyber.Agent.PromptTest do
  @moduledoc """
  T14c AC1 — prompt-as-delta: the prompt the model sees is answered as a
  STORE DELTA (`PromptAssembled`), never an ephemeral model echo — a
  first-class, mergeable store artifact with EXACTLY three pointers
  (`sessionId` first — the kind marker that routes to no subscription and
  matches no lens; the two `requestRef` readers — `Engine.answered?/2` and
  the conversation lens — key on the FIRST role, so requestRef-first would
  weld the retry window shut and poison re-derivation). Two boots over the
  same store produce byte-identical prompt answers: re-derivation is a pure
  function of store state, and the replay pre-check re-sends the stored
  bytes instead of minting a second claim.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Engine, Events, Prompt}

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)

  # ------------------------------------------------------------- scaffolding

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      send(state.reply_to, {:llm_request, JSON.decode!(body)})

      content =
        case state.respond do
          fun when is_function(fun, 1) -> fun.(JSON.decode!(body))
          text -> text
        end

      body =
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => content}}
          ]
        })

      {:ok, %{status: 200, body: body}}
    end
  end

  defp llm(respond) do
    {:ok, handler} =
      Kyber.Agent.LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: self(), respond: respond}}
      )

    handler
  end

  defp start_store(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp put_wire(store, wire) do
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp start_engine(store, respond, opts \\ []) do
    test = self()

    {:ok, engine} =
      Engine.start_link(
        Keyword.merge(
          [
            name: nil,
            llm: llm(respond),
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
    {:ok, signed} =
      Kyber.Events.message_received(@human_seed, ts, msg_id, "chan-1", "session:s1", content)

    put_wire(store, Wire.envelope(signed))
  end

  # the same request-inference choreography the daemon drives: the real
  # context builder turns the prompt into an InferenceRequested, then the
  # engine's gather handler casts it in
  defp request_inference(store, engine, prompt_delta, memories \\ []) do
    builder =
      Kyber.Agent.ContextBuilder.handler(
        seed: @agent_seed,
        store: fn -> Agent.get(store, & &1) end,
        memory: {Kyber.Agent.MemoryPort.Stub, %{memories: memories}}
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

  defp of_type(set, type) do
    Enum.filter(set, fn {_id, {claims, _sig}} ->
      match?(%{type: ^type}, Schema.resolve(claims))
    end)
  end

  # the PromptAssembled content (the typed resolution sheds the string tag)
  defp stored_content(%{content: canonical}) when is_binary(canonical), do: canonical

  # ------------------------------------------------------------------ tests

  test "AC1: the prompt is a store delta — exactly one PromptAssembled, sessionId-first, re-derivation byte-equals stored content" do
    store = start_store(%{})
    engine = start_engine(store, "Paris.")

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "Capital of France?")
    request = request_inference(store, engine, prompt)
    {assembled, _} = sink_typed("PromptAssembled")

    # exactly one PromptAssembled, pointer order pinned: sessionId FIRST
    set = Agent.get(store, & &1)
    assert [_one] = of_type(set, "PromptAssembled")
    [{_id, {claims, _sig}}] = of_type(set, "PromptAssembled")
    assert hd(claims.pointers).role == "sessionId"
    assert assembled.sessionId == {:entity, "session:s1", "prompts"}
    assert assembled.requestRef == {:delta, request.id, "prompted"}

    # the response still lands — the delta was answered, not swallowed
    {response, _} = sink_typed("ResponseDelta")
    assert response.content == "Paris."
    sink_typed("MessageSent")

    # independent re-derivation: assembling from the store state BELOW the
    # claim (the store only learns — the response above it is not input to
    # the prompt) yields BYTE-IDENTICAL canonical content — no wall-clock,
    # no ephemeral echo
    {:delta, request_id, _} = assembled.requestRef
    typed_request = Schema.resolve(request.claims)
    memory_ids = for {:delta, id, _ctx} <- typed_request.memoryPointers, do: id

    set_below = below(set, assembled.timestamp)

    re_derived = Prompt.assemble(set_below, "session:s1", memory_ids, 8)
    assert Prompt.canonical(re_derived) == stored_content(assembled)
    assert request_id == request.id
  end

  test "AC1: the stub-LLM capture equals the decoded stored content — sent == stored, structurally" do
    store = start_store(%{})
    engine = start_engine(store, "ok")

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "What is the cap?")
    request_inference(store, engine, prompt)
    {assembled, _} = sink_typed("PromptAssembled")
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # what the model's API received is EXACTLY the decoded store artifact
    assert_receive {:llm_request, body}
    assert {:ok, body["messages"]} == Prompt.decode(stored_content(assembled))
    assert hd(body["messages"]) == %{"role" => "system", "content" => Prompt.system_prompt()}
  end

  test "AC1: the replay pre-check — a stored PromptAssembled with no answer re-sends THOSE bytes, emits no second claim" do
    store = start_store(%{})

    # the crash-between-emit-and-answer window: the request and its
    # PromptAssembled are in the store, the ResponseDelta never landed
    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "Replay me.")
    {:entity, session_id, _} = pointer(prompt.claims, "session")

    {:ok, ir_signed} =
      Events.inference_requested(
        @agent_seed,
        1_700_000_000_000,
        "stub-model",
        session_id,
        prompt.id,
        prompt.id,
        []
      )

    request = put_wire(store, Wire.envelope(ir_signed))
    set_before = Agent.get(store, & &1)

    messages = Prompt.assemble(set_before, session_id, [], 8)
    canonical = Prompt.canonical(messages)

    {:ok, pa_signed} =
      Events.prompt_assembled(
        @agent_seed,
        1_700_000_000_000,
        request.id,
        session_id,
        canonical
      )

    put_wire(store, Wire.envelope(pa_signed))

    # a cold engine boots over the store and the SAME request re-fires
    engine = start_engine(store, "replayed.")
    assert Engine.handler(engine).([request]) == []

    # the model saw the STORED bytes — byte-identical, never re-assembled
    assert_receive {:llm_request, body}
    assert {:ok, body["messages"]} == Prompt.decode(canonical)

    # and NO second PromptAssembled was minted — exactly-one survives
    set = Agent.get(store, & &1)
    assert [_one] = of_type(set, "PromptAssembled")

    # the turn completed from the replayed prompt
    {response, _} = sink_typed("ResponseDelta")
    assert response.content == "replayed."
    sink_typed("MessageSent")
  end

  test "AC1: second cold boot over the same store emits zero new deltas" do
    store = start_store(%{})
    engine = start_engine(store, "Paris.")

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "Capital of France?")
    request = request_inference(store, engine, prompt)
    sink_typed("PromptAssembled")
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    # T14h: the answer path's zero-charge StandingDigest emission
    sink_typed("StandingDigest")
    assert_receive {:llm_request, _body}

    size_before = map_size(Agent.get(store, & &1))

    # a SECOND cold engine over the SAME store: the answered request is a
    # counted skip — zero new deltas, zero model calls
    engine2 = start_engine(store, "never sent")
    assert Engine.handler(engine2).([request]) == []
    assert %{skipped: 1} = Engine.status(engine2)

    refute_receive {:llm_request, _body}, 100
    refute_receive {:sink, _wire}, 100
    assert map_size(Agent.get(store, & &1)) == size_before
  end

  test "AC1 mutation knob: an unadmitted MemoryEdited is absent from the assembled prompt; admitting it re-derives a DIFFERENT id" do
    store = start_store(%{})

    {:ok, memory} =
      Events.memory_entity(
        @agent_seed,
        1_600_000_000_000,
        "memory:cap",
        "the cap is a lens, never a store property",
        []
      )

    base_delta = put_wire(store, Wire.envelope(memory))

    # the edit is built FIRST — wired into the request's memoryPointers —
    # but deliberately NOT admitted: the gather reads the referenced
    # delta's OWN content (Map.get miss ⇒ note absent)
    {:ok, edited} =
      Events.memory_edited(
        @agent_seed,
        1_600_000_100_000,
        base_delta.id,
        "MUTATION-KNOB-NOTE: the cap is a lens, never a store property",
        "human_edit"
      )

    edited_id = Wire.envelope(edited)["id"]
    engine = start_engine(store, "ok")

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "What is the cap?")
    request_inference(store, engine, prompt, [edited_id])
    {assembled_unadmitted, pa_delta_unadmitted} = sink_typed("PromptAssembled")
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # the unadmitted edit's note is ABSENT from the emitted prompt
    refute stored_content(assembled_unadmitted) =~ "MUTATION-KNOB-NOTE"

    # admit the edit, then re-derive: the note appears ⇒ the re-derived
    # claim MUST differ (positive content-sensitivity — kills the
    # hardcoded-constant placebo)
    put_wire(store, Wire.envelope(edited))
    set = Agent.get(store, & &1)

    re_derived = Prompt.assemble(set, "session:s1", [edited_id], 8)
    canonical = Prompt.canonical(re_derived)
    assert canonical =~ "MUTATION-KNOB-NOTE"

    {:ok, pa_signed} =
      Events.prompt_assembled(
        @agent_seed,
        1_700_000_000_000,
        request_id_of(assembled_unadmitted),
        "session:s1",
        canonical
      )

    re_derived_id = Wire.envelope(pa_signed)["id"]
    refute re_derived_id == pa_delta_unadmitted.id
  end

  # -------------------------------------------------------------- machinery

  # the store state at-or-below a timestamp — re-derivation reads the
  # state the claim was assembled from, never the deltas above it
  defp below(set, ts) do
    # T14h: the digest family is minted AFTER the PromptAssembled (the
    # answer path's zero-charge side emission) — the as-of-mint set excludes
    # it; the map shape is the DeltaSet contract
    set
    |> Enum.filter(fn {_id, {claims, _sig}} ->
      claims.timestamp <= ts and
        not match?(
          %{type: type} when type in ["StandingDigest", "EpochKeyMaterial"],
          Schema.resolve(claims)
        )
    end)
    |> Map.new()
  end

  defp request_id_of(%{requestRef: {:delta, id, _ctx}}), do: id

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
