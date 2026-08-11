defmodule Kyber.Agent.FirstAssemblyTest do
  @moduledoc """
  T14g (the T14f first-assembly fix, riding R1) — the skill lens fired ONLY
  on rebuild_pending (engine.ex:508): the PRIMARY infer path (engine.ex:200)
  never passed `prompt_text`, so the lens was DARK on first assembly. This
  build passes `prompt_text` at :200 — the witness: a FIRST assembly (no
  prior conversation, no tool chain) renders the skill note through the
  real engine path. The lens itself is the T14f fail-closed lens (epoch-
  gated, exact-name + digest tiers, 4-skill/8192-byte caps) — unchanged.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, Events, LlmHandler, MemoryPort, Prompt}

  @agent_seed String.duplicate("b2", 32)
  @human_seed String.duplicate("a1", 32)
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

  defp start_engine(store) do
    test = self()

    {:ok, engine} =
      Engine.start_link(
        name: nil,
        llm: llm(),
        store: fn -> Agent.get(store, & &1) end,
        sink: fn wire ->
          put_wire(store, wire)
          send(test, {:sink, wire})
          {:ok, :persisted}
        end
      )

    engine
  end

  defp ingest_received(store, ts, msg_id, content) do
    {:ok, signed} =
      Kyber.Events.message_received(@human_seed, ts, msg_id, "chan-1", "session:s1", content)

    wire = Wire.envelope(signed)
    put_wire(store, wire)
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

  test "the first assembly renders the skill note — the primary infer path passes prompt_text (engine.ex:200)" do
    store = start_store()

    # a skill the lens can see: a SkillSet + the skill-family epoch allowing it
    {:ok, skill} = Events.skill_set(@agent_seed, @ts, "greet", "Greet a new member", "say hello warmly")
    {:ok, epoch} = Events.skill_policy(@agent_seed, @ts + 1, ["greet"])
    put_wire(store, Wire.envelope(skill))
    put_wire(store, Wire.envelope(epoch))

    engine = start_engine(store)

    # the FIRST prompt of the session: no prior conversation, no tool chain —
    # the assemble happens on the PRIMARY path (engine.ex:200)
    prompt = ingest_received(store, @ts + 10, "msg-1", "please greet the new member")
    request_inference(store, engine, prompt)
    sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # the skill note rides the FIRST assembly — the lens fired at :200
    assert Enum.any?(body["messages"], fn m ->
             is_binary(m["content"]) and String.starts_with?(m["content"], "Skill: greet")
           end)

    # and the block slot holds: system -> skill -> user turn (no identity
    # block under a nil seed)
    assert hd(body["messages"])["content"] == Prompt.system_prompt()
    assert List.last(body["messages"]) == %{"role" => "user", "content" => "please greet the new member"}
  end

  test "a prompt with NO skill match contributes no skill note on first assembly — the lens stays fail-closed" do
    store = start_store()
    {:ok, skill} = Events.skill_set(@agent_seed, @ts, "deploy", "Deploy the service", "mix release")
    {:ok, epoch} = Events.skill_policy(@agent_seed, @ts + 1, ["deploy"])
    put_wire(store, Wire.envelope(skill))
    put_wire(store, Wire.envelope(epoch))

    engine = start_engine(store)
    prompt = ingest_received(store, @ts + 10, "msg-1", "what is the weather?")
    request_inference(store, engine, prompt)
    sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    refute Enum.any?(body["messages"], fn m -> is_binary(m["content"]) and String.starts_with?(m["content"], "Skill: ") end)
  end

  test "an ungoverned skill family contributes NO skill note on first assembly (fail-closed lens, unchanged)" do
    store = start_store()
    {:ok, skill} = Events.skill_set(@agent_seed, @ts, "greet", "Greet a new member", "say hello warmly")
    put_wire(store, Wire.envelope(skill))

    engine = start_engine(store)
    prompt = ingest_received(store, @ts + 10, "msg-1", "please greet the new member")
    request_inference(store, engine, prompt)
    sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    refute Enum.any?(body["messages"], fn m -> is_binary(m["content"]) and String.starts_with?(m["content"], "Skill: ") end)
  end
end
