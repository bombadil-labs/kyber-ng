defmodule Kyber.Agent.EngineTest do
  @moduledoc """
  T11b — the engine: fires on `InferenceRequested`, rehydrates context by
  pointer-walk (the store is the memory — AC5), applies the window lens,
  calls the model through the injected handler, and emits `ResponseDelta` +
  `message.sent` through its sink. Async by design: the gather's route call
  returns immediately; the sink message is the completion signal
  (assert_receive, never sleep).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Events, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, MemoryPort}

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

  # a tiny in-memory store the engine reads through its :store seam; the
  # sink records every emitted wire back into it (what the daemon would do)
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
      Events.message_received(@human_seed, ts, msg_id, "chan-1", "session:s1", content)

    wire = Wire.envelope(signed)
    put_wire(store, wire)
  end

  # run the prompt through the real context builder and hand the request to
  # the engine's gather handler — the same path the daemon drives
  defp request_inference(store, engine, prompt_delta, memories \\ []) do
    builder =
      ContextBuilder.handler(
        seed: @agent_seed,
        store: fn -> Agent.get(store, & &1) end,
        memory: {MemoryPort.Stub, %{memories: memories}}
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

  # ------------------------------------------------------------------ tests

  test "fires on InferenceRequested: rehydrates by pointer-walk, emits ResponseDelta + message.sent" do
    store = start_store(%{})
    engine = start_engine(store, "Paris.")

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "Capital of France?")
    request = request_inference(store, engine, prompt)

    {response, response_delta} = sink_typed("ResponseDelta")
    assert response.requestRef == {:delta, request.id, "answered"}
    assert response.content == "Paris."

    {sent, _} = sink_typed("MessageSent")
    assert sent.content == "Paris."
    assert sent.via == {:entity, "chan-1", "sent"}
    assert sent.caused_by == {:delta, response_delta.id, nil}

    # the model saw the question — rehydrated from the store, not passed inline
    assert_receive {:llm_request, body}
    assert List.last(body["messages"]) == %{"role" => "user", "content" => "Capital of France?"}
  end

  test "AC5: the second invocation is grounded in the first exchange (the store is the memory)" do
    store = start_store(%{})

    # the grounded answer is only possible if the model SAW its own prior
    # turn — the stub answers from the assistant message in its context
    respond = fn body ->
      messages = body["messages"]

      if List.last(messages)["content"] == "What did I just say?" do
        case Enum.find(messages, &(&1["role"] == "assistant")) do
          %{"content" => prior} -> "You said: " <> prior
          nil -> "I have no memory of that."
        end
      else
        "Understood: blue."
      end
    end

    engine = start_engine(store, respond)

    first = ingest_received(store, 1_700_000_000_000, "msg-1", "My favorite color is blue.")
    request_inference(store, engine, first)
    {first_answer, _} = sink_typed("ResponseDelta")
    assert first_answer.content == "Understood: blue."
    sink_typed("MessageSent")

    followup = ingest_received(store, 1_700_000_100_000, "msg-2", "What did I just say?")
    request_inference(store, engine, followup)

    # the model's context contained the FIRST exchange — both sides of it
    assert_receive {:llm_request, _first_body}
    assert_receive {:llm_request, body}
    texts = Enum.map(body["messages"], & &1["content"])
    assert Enum.any?(texts, &(&1 == "My favorite color is blue."))
    assert Enum.any?(texts, &(&1 == "Understood: blue."))

    {second_answer, _} = sink_typed("ResponseDelta")
    assert second_answer.content =~ "blue"
  end

  test "an already-answered request is a counted skip, never a second model call" do
    store = start_store(%{})
    engine = start_engine(store, "Paris.")

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "Capital of France?")
    request = request_inference(store, engine, prompt)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    assert_receive {:llm_request, _body}

    # the crash-window re-fire: the SAME request routed again
    assert Engine.handler(engine).([request]) == []
    assert %{skipped: 1} = Engine.status(engine)
    refute_receive {:llm_request, _body}, 100
    refute_receive {:sink, _wire}, 100
  end

  test "the window lens: only the last N turns ride; summaries cover the elided head" do
    store = start_store(%{})
    engine = start_engine(store, "ok", window: 2)

    # an elided head, covered by a persisted ConversationSummary
    old = ingest_received(store, 1_700_000_000_000, "msg-old", "ancient question")

    {:ok, summary} =
      Kyber.Agent.Events.conversation_summary(
        @agent_seed,
        1_700_000_050_000,
        "session:s1",
        "Earlier: the user asked an ancient question.",
        [old.id]
      )

    put_wire(store, Wire.envelope(summary))

    a = ingest_received(store, 1_700_000_100_000, "msg-a", "penultimate question")
    _b = ingest_received(store, 1_700_000_200_000, "msg-b", "final question")

    prompt = ingest_received(store, 1_700_000_300_000, "msg-c", "and now?")
    request_inference(store, engine, prompt)

    assert_receive {:llm_request, body}
    texts = Enum.map(body["messages"], & &1["content"])

    # windowed out: the ancient turn's text is absent; its summary is present
    refute Enum.any?(texts, &(&1 == "ancient question"))
    assert Enum.any?(texts, &(&1 =~ "ancient question elided" or &1 =~ "Earlier:"))
    refute Enum.any?(texts, &(&1 == "penultimate question"))
    assert Enum.any?(texts, &(&1 == "and now?"))
    assert a
  end

  test "memory pointers rehydrate as content through the pointer-walk" do
    store = start_store(%{})
    engine = start_engine(store, "ok")

    {:ok, memory} =
      Kyber.Agent.Events.memory_entity(
        @agent_seed,
        1_600_000_000_000,
        "memory:cap",
        "the cap is a lens, never a store property",
        []
      )

    memory_delta = put_wire(store, Wire.envelope(memory))

    prompt = ingest_received(store, 1_700_000_000_000, "msg-1", "What is the cap?")
    request_inference(store, engine, prompt, [memory_delta.id])

    assert_receive {:llm_request, body}
    texts = Enum.map(body["messages"], & &1["content"])
    assert Enum.any?(texts, &(&1 =~ "the cap is a lens, never a store property"))
  end
end
