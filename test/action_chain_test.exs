defmodule Kyber.Agent.ActionChainTest do
  @moduledoc """
  T12 AC1 — the chain is the same chain: a tool turn produces `ToolCall` →
  gate decision → executor action → `ToolResult`, each persisted and
  pointer-linked, with a REAL fs action (`fs.read` against a tmp workspace);
  the projection shows the action as a tool step. A mid-chain restart
  resumes with the executor answering from the store — the action is NEVER
  re-executed after a crash-window re-fire (the byte-identical re-fire
  holds).

  AC10 (carried) — the stub registry and the real action registry are
  A/B-swappable behind the same executor seam.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Events, Schema, Store, Wire}
  alias Kyber.Agent.{Action, ContextBuilder, Engine, MemoryPort, Projection, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)
  @fixture_content "the oracle answer is 42"

  # the two-phase stub model: asks for fs_read (native tool_calls, typed
  # args), then answers from the tool result
  defp read_then_answer(body) do
    case Enum.find(body["messages"], &(&1["role"] == "tool")) do
      %{"content" => result} -> "The file says: " <> result
      nil -> tool_calls_message("fs_read", JSON.encode!(%{"path" => "notes.txt"}))
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
      message = state.respond.(decoded)

      message =
        if is_binary(message), do: %{"role" => "assistant", "content" => message}, else: message

      {:ok,
       %{status: 200, body: JSON.encode!(%{"choices" => [%{"index" => 0, "message" => message}]})}}
    end
  end

  defp tmp_workspace do
    ws = Path.join(System.tmp_dir!(), "kyber-t12-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "notes.txt"), @fixture_content)
    on_exit(fn -> File.rm_rf(ws) end)
    ws
  end

  defp start_store, do: elem(Agent.start_link(fn -> %{} end), 1)

  defp store_fn(store), do: fn -> Agent.get(store, & &1) end

  defp put_wire(store, wire) do
    {:ok, delta} = Store.verify(wire)
    Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
    delta
  end

  defp start_engine(store, respond) do
    test = self()
    registry = Action.registry()

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
        tools: ToolExecutor.tool_specs(registry),
        tool_keys: ToolExecutor.tool_key_map(registry),
        store: store_fn(store),
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
        store: store_fn(store),
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

  # the real executor leg: the action registry + gate + workspace context,
  # answering through the store (never re-executing a decided call)
  defp run_executor(store, call_delta, workspace) do
    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: Action.registry(),
        gate: Gate.new(allow: ["fs.read"]),
        context: Action.context(workspace: workspace),
        store: store_fn(store)
      )

    wires = handler.([call_delta])
    Enum.each(wires, &put_wire(store, &1))
    wires
  end

  # ------------------------------------------------------------------ tests

  test "AC1: ToolCall -> gate decision -> executor action -> ToolResult, persisted and pointer-linked" do
    workspace = tmp_workspace()
    store = start_store()
    engine = start_engine(store, &read_then_answer/1)
    {prompt, request} = ingest_prompt(store, engine, "What is in notes.txt?")

    {call, call_delta} = sink_typed("ToolCall")
    assert call.requestRef == {:delta, request.id, "tool_use"}
    assert call.tool == {:entity, "fs.read", "calls"}
    assert JSON.decode!(call.args) == %{"path" => "notes.txt"}

    assert [gate_wire, result_wire] = run_executor(store, call_delta, workspace)

    # the gate decision is an attested delta, pointer-linked to the call
    {:ok, gate_delta} = Store.verify(gate_wire)
    gate = Schema.resolve(gate_delta.claims)
    assert gate.type == "GateDecision"
    assert gate.decides == {:delta, call_delta.id, "decided"}
    assert gate.verdict == "allow"
    assert gate.policy == "allow"

    # the action ran for real: the ToolResult carries the file's content
    {:ok, result_delta} = Store.verify(result_wire)
    result = Schema.resolve(result_delta.claims)
    assert result.call == {:delta, call_delta.id, "result"}
    assert result.result == @fixture_content
    assert result.status == "ok"

    # every link persisted
    set = Agent.get(store, & &1)
    assert Map.has_key?(set, gate_wire["id"])
    assert Map.has_key?(set, result_wire["id"])

    # the engine resumes the turn from the ToolResult
    assert Engine.handler(engine).([result_delta]) == []
    {response, _} = sink_typed("ResponseDelta")
    assert response.requestRef == {:delta, request.id, "answered"}
    assert response.content == "The file says: " <> @fixture_content

    # the projection shows the action as a tool step — a lens over the SAME store
    set = Agent.get(store, & &1)
    assert {:ok, exchange} = Projection.exchange(set, prompt.id)
    assert exchange.response == "The file says: " <> @fixture_content

    assert [
             %{tool: "fs.read", result: @fixture_content, status: "ok"} = step
           ] = exchange.steps

    assert JSON.decode!(step.args) == %{"path" => "notes.txt"}
  end

  test "AC1: a crash-window re-fire answers from the store — the action is NEVER re-executed" do
    workspace = tmp_workspace()
    store = start_store()
    engine = start_engine(store, &read_then_answer/1)
    {_prompt, _request} = ingest_prompt(store, engine, "Read notes.txt.")
    {_call, call_delta} = sink_typed("ToolCall")

    first_wires = run_executor(store, call_delta, workspace)
    assert [_gate_wire, result_wire] = first_wires

    # the world changes underneath: a re-execution would answer DIFFERENT bytes
    File.write!(Path.join(workspace, "notes.txt"), "tampered after the fact")

    # the crash-window re-fire: a FRESH executor handler (a restart lost all
    # in-process state) sees the same call delta over the same store
    refire_wires = run_executor(store, call_delta, workspace)

    # the byte-identical re-fire holds: both wires re-emitted from the store
    assert refire_wires == first_wires

    # and the answer is the ORIGINAL content — the file was not re-read
    {:ok, delta} = Store.verify(result_wire)
    assert Schema.resolve(delta.claims).result == @fixture_content
  end

  test "AC1: a mid-chain engine restart resumes from the persisted chain (the chain is the state)" do
    workspace = tmp_workspace()
    store = start_store()
    engine = start_engine(store, &read_then_answer/1)
    {_prompt, request} = ingest_prompt(store, engine, "Read notes.txt.")
    {_call, call_delta} = sink_typed("ToolCall")
    run_executor(store, call_delta, workspace)

    # the crash: the engine dies with the turn in flight — pending state gone
    GenServer.stop(engine)

    fresh = start_engine(store, &read_then_answer/1)
    assert Engine.resume(fresh) == %{resumed: 1, waiting: 0}

    {response, _} = sink_typed("ResponseDelta")
    assert response.requestRef == {:delta, request.id, "answered"}
    assert response.content == "The file says: " <> @fixture_content
  end

  test "AC10: stub and real registries are A/B-swappable behind the same executor seam" do
    workspace = tmp_workspace()
    store = start_store()
    request_id = String.duplicate("cd", 32)

    # --- A: the stub registry (T11b's tool:echo), gated allow
    {:ok, signed} =
      AgentEvents.tool_call(@agent_seed, 1_700_000_000_000.0, "tool:echo", "ping", request_id)

    stub_call = put_wire(store, Wire.envelope(signed))

    stub_handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: ToolExecutor.stub_tools(),
        gate: Gate.new(allow: ["tool:echo"]),
        store: store_fn(store)
      )

    assert [_gate_wire, stub_result_wire] = stub_handler.([stub_call])
    {:ok, stub_result} = Store.verify(stub_result_wire)
    assert Schema.resolve(stub_result.claims).result == "ping"

    # --- B: the real action registry (fs.read), same seam
    {:ok, signed2} =
      AgentEvents.tool_call(
        @agent_seed,
        1_700_000_000_001.0,
        "fs.read",
        JSON.encode!(%{"path" => "notes.txt"}),
        request_id
      )

    real_call = put_wire(store, Wire.envelope(signed2))

    real_handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: Action.registry(),
        gate: Gate.new(allow: ["fs.read"]),
        context: Action.context(workspace: workspace),
        store: store_fn(store)
      )

    assert [_gate_wire2, real_result_wire] = real_handler.([real_call])
    {:ok, real_result} = Store.verify(real_result_wire)
    assert Schema.resolve(real_result.claims).result == @fixture_content

    # the model-facing specs ride the same seam for both registry shapes
    stub_names =
      for spec <- ToolExecutor.tool_specs(ToolExecutor.stub_tools()), do: spec["function"]["name"]

    real_specs = ToolExecutor.tool_specs(Action.registry())
    real_names = for spec <- real_specs, do: spec["function"]["name"]

    assert "tool_echo" in stub_names
    assert "fs_read" in real_names

    fs_read = Enum.find(real_specs, &(&1["function"]["name"] == "fs_read"))
    assert fs_read["function"]["parameters"]["properties"]["path"]["type"] == "string"
  end
end
