defmodule Kyber.Agent.ToolChainTest do
  @moduledoc """
  T11b AC8 — tool chains are linked deltas: `InferenceRequested` → `ToolCall`
  → `ToolResult` → final `ResponseDelta`, each persisted and pointer-linked;
  the engine's in-flight state survives a restart (the chain IS the state);
  the UI projection is a lens over the same store — collapsed and expanded
  views, no special store path.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Events, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, MemoryPort, Projection, ToolExecutor}
  alias Kyber.Agent.Action.Gate

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)

  # the two-phase stub model: asks for the echo tool (native tool_calls),
  # then answers from its result
  defp tool_then_answer(body) do
    case Enum.find(body["messages"], &(&1["role"] == "tool")) do
      %{"content" => result} -> "The tool said: " <> result
      nil -> tool_calls_message("tool_echo", "{\"args\":\"ping-pong\"}")
    end
  end

  defp tool_calls_message(name, arguments) do
    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => "call_test1",
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      ]
    }
  end

  # ------------------------------------------------------------- scaffolding

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      decoded = JSON.decode!(body)
      send(state.reply_to, {:llm_request, decoded})

      # the respond closure answers a plain string (content) or a full
      # assistant message map (native tool_calls)
      message = state.respond.(decoded)

      message =
        if is_binary(message),
          do: %{"role" => "assistant", "content" => message},
          else: message

      {:ok,
       %{
         status: 200,
         body:
           JSON.encode!(%{
             "choices" => [%{"index" => 0, "message" => message}]
           })
       }}
    end
  end

  defp start_store, do: elem(Agent.start_link(fn -> %{} end), 1)

  defp put_wire(store, wire) do
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp start_engine(store, respond, opts \\ []) do
    test = self()

    {:ok, llm} =
      Kyber.Agent.LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: test, respond: respond}}
      )

    {:ok, engine} =
      Engine.start_link(
        name: nil,
        llm: llm,
        window: Keyword.get(opts, :window, 8),
        store: fn -> Agent.get(store, & &1) end,
        sink: fn wire ->
          put_wire(store, wire)
          send(test, {:sink, wire})
          {:ok, :persisted}
        end
      )

    engine
  end

  defp ingest_prompt(store, engine_or_nil, content) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        1_700_000_000_000,
        "msg-1",
        "chan-1",
        "session:s1",
        content
      )

    prompt = put_wire(store, Wire.envelope(signed))

    builder =
      ContextBuilder.handler(
        seed: @agent_seed,
        store: fn -> Agent.get(store, & &1) end,
        memory: {MemoryPort.Stub, %{}}
      )

    [request_wire] = builder.([prompt])
    request = put_wire(store, request_wire)
    if engine_or_nil, do: assert(Engine.handler(engine_or_nil).([request]) == [])
    {prompt, request}
  end

  defp sink_typed(type) do
    assert_receive {:sink, wire}, 2_000
    {:ok, delta} = Store.verify(wire)

    case Schema.resolve(delta.claims) do
      %{type: ^type} = typed -> {typed, delta}
      _other -> sink_typed(type)
    end
  end

  # receive sink wires until the tally covers every wanted type — a
  # lossless running count (nothing is discarded, order-agnostic)
  defp collect_sinks(wants, tally) do
    if Enum.all?(wants, fn {type, n} -> Map.get(tally, type, 0) >= n end) do
      tally
    else
      assert_receive {:sink, wire}, 2_000
      {:ok, delta} = Store.verify(wire)

      type =
        case Schema.resolve(delta.claims) do
          %{type: t} -> t
          _raw -> nil
        end

      collect_sinks(wants, Map.update(tally, type, 1, &(&1 + 1)))
    end
  end

  # T12: every call crosses the gate before the executor runs it — this
  # slice's posture is allow-all-by-default (the unknown-tool test needs
  # `tool:nonexistent` to reach the executor); T12's own tests exercise
  # deny/prompt. Both output wires persist (the decision is attested).
  defp run_executor(store, call_delta) do
    [gate_wire, result_wire] = executor_handler(store).([call_delta])
    put_wire(store, gate_wire)
    {result_wire, put_wire(store, result_wire)}
  end

  defp executor_handler(store) do
    ToolExecutor.handler(
      seed: @agent_seed,
      gate: Gate.new(default: :allow),
      store: fn -> Agent.get(store, & &1) end
    )
  end

  # ------------------------------------------------------------------ tests

  test "the chain is linked deltas: request -> ToolCall -> ToolResult -> final ResponseDelta" do
    store = start_store()
    engine = start_engine(store, &tool_then_answer/1)
    {_prompt, request} = ingest_prompt(store, engine, "Play ping with the echo tool.")

    {call, call_delta} = sink_typed("ToolCall")
    assert call.requestRef == {:delta, request.id, "tool_use"}
    assert call.tool == {:entity, "tool:echo", "calls"}
    assert call.args == "ping-pong"

    {_result_wire, result_delta} = run_executor(store, call_delta)
    result = Schema.resolve(result_delta.claims)
    assert result.call == {:delta, call_delta.id, "result"}
    assert result.result == "ping-pong"
    assert result.status == "ok"

    assert Engine.handler(engine).([result_delta]) == []

    {response, _response_delta} = sink_typed("ResponseDelta")
    assert response.requestRef == {:delta, request.id, "answered"}
    assert response.content == "The tool said: ping-pong"

    {sent, _} = sink_typed("MessageSent")
    assert sent.content == "The tool said: ping-pong"
  end

  test "the executor is deterministic: a re-fired call yields the byte-identical result" do
    store = start_store()
    engine = start_engine(store, &tool_then_answer/1)
    ingest_prompt(store, engine, "Echo something.")
    {_call, call_delta} = sink_typed("ToolCall")

    {wire1, _} = run_executor(store, call_delta)
    [_gate_wire2, wire2] = executor_handler(store).([call_delta])
    assert wire1 == wire2
  end

  test "an unknown tool completes the chain with a recorded failure, never a repair" do
    store = start_store()

    engine =
      start_engine(store, fn body ->
        case Enum.find(body["messages"], &(&1["role"] == "tool")) do
          nil -> tool_calls_message("tool_nonexistent", "{}")
          %{"content" => result} -> "Tool trouble: " <> result
        end
      end)

    ingest_prompt(store, engine, "Use a tool that does not exist.")
    {_call, call_delta} = sink_typed("ToolCall")
    {_wire, result_delta} = run_executor(store, call_delta)

    result = Schema.resolve(result_delta.claims)
    assert result.status == "unknown_tool"
    assert result.result =~ "tool:nonexistent"

    assert Engine.handler(engine).([result_delta]) == []
    {response, _} = sink_typed("ResponseDelta")
    assert response.content =~ "unknown tool"
  end

  test "mid-chain restart: a fresh engine resumes from the persisted chain (the chain is the state)" do
    store = start_store()
    engine = start_engine(store, &tool_then_answer/1)
    {_prompt, request} = ingest_prompt(store, engine, "Play ping with the echo tool.")

    {_call, call_delta} = sink_typed("ToolCall")
    run_executor(store, call_delta)

    # the crash: the engine dies with the turn in flight — pending state gone
    GenServer.stop(engine)

    fresh = start_engine(store, &tool_then_answer/1)
    assert Engine.resume(fresh) == %{resumed: 1, waiting: 0}

    {response, _} = sink_typed("ResponseDelta")
    assert response.requestRef == {:delta, request.id, "answered"}
    assert response.content == "The tool said: ping-pong"
  end

  test "a chain whose ToolCall still awaits its result is left waiting, not re-modeled" do
    store = start_store()
    engine = start_engine(store, &tool_then_answer/1)
    ingest_prompt(store, engine, "Play ping with the echo tool.")
    sink_typed("ToolCall")
    assert_receive {:llm_request, _body}

    GenServer.stop(engine)
    fresh = start_engine(store, &tool_then_answer/1)

    assert Engine.resume(fresh) == %{resumed: 0, waiting: 1}
    refute_receive {:llm_request, _body}, 100
  end

  test "spine 8: a long session emits one deterministic ConversationSummary checkpoint" do
    store = start_store()
    engine = start_engine(store, fn _body -> "the answer" end, window: 2)

    # synchronize each turn before the next ingest (the engine answers
    # casts in order, so turn i's snapshot then holds EXACTLY turns 1..i-1
    # complete plus prompt i — the checkpoint's cover count is otherwise
    # scheduler-dependent: a lagging snapshot sees the next prompt and
    # covers more; a latent race this slice's heavier async suite exposed).
    # The tally collector never loses a wire (unlike sink_typed/1, which
    # discards non-matching types — the summary rides the same sink and can
    # arrive mid-drain).
    tally =
      Enum.reduce(1..5, %{}, fn i, tally ->
        ingest_prompt(store, engine, "Prompt #{i}.")
        collect_sinks(%{"MessageSent" => i}, tally)
      end)

    tally = collect_sinks(%{"ConversationSummary" => 1}, tally)
    assert tally["MessageSent"] == 5

    # the sink persists before it notifies — the store read is synchronized
    set = Agent.get(store, & &1)

    summaries =
      for {_id, {claims, _sig}} <- set,
          %{type: "ConversationSummary"} = typed <- [Schema.resolve(claims)],
          do: typed

    assert [summary] = summaries
    assert summary.content =~ "Summary of turns"
    # the elided head covered; the checkpoint is a lens artifact
    assert length(summary.covers) == 3
  end

  test "the projection is a lens: collapsed and expanded views of the SAME store" do
    store = start_store()
    engine = start_engine(store, &tool_then_answer/1)
    {prompt, _request} = ingest_prompt(store, engine, "Play ping with the echo tool.")

    {_call, call_delta} = sink_typed("ToolCall")
    {_wire, result_delta} = run_executor(store, call_delta)
    Engine.handler(engine).([result_delta])
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    set = Agent.get(store, & &1)
    assert {:ok, exchange} = Projection.exchange(set, prompt.id)

    assert exchange.prompt == "Play ping with the echo tool."
    assert exchange.response == "The tool said: ping-pong"

    assert [step] = exchange.steps
    assert step.tool == "tool:echo"
    assert step.args == "ping-pong"
    assert step.result == "ping-pong"
    assert step.status == "ok"

    collapsed = Projection.render(exchange, :collapsed)
    expanded = Projection.render(exchange, :expanded)

    assert collapsed == [
             "user: Play ping with the echo tool.",
             "agent: The tool said: ping-pong"
           ]

    assert expanded == [
             "user: Play ping with the echo tool.",
             "tool tool:echo(ping-pong) -> ping-pong [ok]",
             "agent: The tool said: ping-pong"
           ]
  end

  test "the projection of an in-flight chain shows the steps so far and no response" do
    store = start_store()
    engine = start_engine(store, &tool_then_answer/1)
    {prompt, _request} = ingest_prompt(store, engine, "Play ping with the echo tool.")
    sink_typed("ToolCall")

    set = Agent.get(store, & &1)
    assert {:ok, exchange} = Projection.exchange(set, prompt.id)
    assert exchange.response == nil
    assert [%{tool: "tool:echo", result: nil}] = exchange.steps
  end
end
