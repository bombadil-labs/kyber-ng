defmodule Kyber.Agent.AlwaysOnTest do
  @moduledoc """
  T14g AC1 — the always-on identity block (G3): a boot with a soul + user
  doc renders them FIRST in the assembled prompt, deterministic, capped at
  8192 rendered bytes, NEVER windowed. The byte-identity is written against
  the pinned render format (H5): `"Soul: "` / `"User: "` / `"Operator: "`
  note spellings, the CLOSED-SET order soul -> user -> operator (never
  `{ts, id}` of heads), the `"Profile: <name>\n"` rules segment AFTER the
  three primitives counting against the same 8192, skip-and-continue per
  primitive (a primitive that would blow the bound is omitted entirely,
  never truncated), and the block's slot system -> identity -> memory ->
  summary -> skill -> elision -> turns.

  The witness boots an ENGINE over a store holding operator-attested
  IdentitySet deltas (the boot context `{profile | nil, operator_author |
  nil}` threaded through `Engine.start_link`), runs a real
  InferenceRequested through the primary infer path, and reads the message
  list the stub model was sent.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, Events, LlmHandler, MemoryPort, Prompt}

  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)
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

  defp start_engine(store, opts) do
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

  # the operator's identity primitives, admitted through the real door
  defp identity_store(body_soul, body_user) do
    store = start_store()

    {:ok, soul} =
      Events.identity_set(@operator_seed, @ts, "identity:soul", "soul", body_soul)

    {:ok, user} =
      Events.identity_set(@operator_seed, @ts + 1, "identity:user", "user", body_user)

    put_wire(store, Wire.envelope(soul))
    put_wire(store, Wire.envelope(user))
    store
  end

  test "AC1: a boot with a soul + user doc renders the identity block FIRST — pinned byte format, closed-set order, before memory/summary/skill/elision/turns" do
    store = identity_store("I am Veles, the quiet archivist.", "The operator prefers terse, factual answers.")
    engine = start_engine(store, boot: {nil, Keys.author_for_seed(@operator_seed)})

    prompt = ingest_received(store, @ts + 10, "msg-1", "Who are you?")
    request_inference(store, engine, prompt)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    assert_receive {:llm_request, body}, 2_000
    messages = body["messages"]

    # the pinned slot: system -> identity -> memory -> summary -> skill ->
    # elision -> turns — the identity notes are the FIRST non-system messages
    assert hd(messages)["role"] == "system"
    assert hd(messages)["content"] == Prompt.system_prompt()

    assert Enum.at(messages, 1) == %{"role" => "system", "content" => "Soul: I am Veles, the quiet archivist."}
    assert Enum.at(messages, 2) == %{"role" => "system", "content" => "User: The operator prefers terse, factual answers."}

    # the conversation turn rides AFTER the identity block
    assert List.last(messages) == %{"role" => "user", "content" => "Who are you?"}
  end

  test "AC1: the block is deterministic — the minted canonical == a fresh assemble == what the model saw (byte-identical)" do
    store = identity_store("soul body", "user body")
    author = Keys.author_for_seed(@operator_seed)

    engine = start_engine(store, boot: {nil, author})
    prompt = ingest_received(store, @ts + 10, "msg-1", "hello")
    request_inference(store, engine, prompt)

    # the minted PromptAssembled rides the store; the stub saw its content
    {pa, _} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, first_body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # the minted canonical == what the model saw, decoded
    assert {:ok, messages} = Prompt.decode(pa.content)
    assert first_body["messages"] == messages

    # a fresh deterministic assemble over the store AS OF MINT TIME (the
    # answer deltas excluded) re-derives the same canonical bytes —
    # re-derivation is a pure function of the set, replica-identical (AC4)
    set = Agent.get(store, & &1)

    as_of_mint =
      Map.reject(set, fn {_id, {claims, _sig}} ->
        match?(%{type: type} when type in ["ResponseDelta", "MessageSent"], Schema.resolve(claims))
      end)

    re_derived = Prompt.assemble(as_of_mint, "session:s1", [], 8, "hello", {nil, author})
    assert Prompt.canonical(re_derived) == pa.content

    # sequential re-boot under the SAME profile: the answered request is a
    # counted skip (exactly-one per (request, profile) — never re-minted)
    engine2 = start_engine(store, boot: {nil, author})
    _ = request_inference(store, engine2, prompt)
    assert %{skipped: 1} = Engine.status(engine2)
  end

  test "AC1: the block is capped at 8192 TOTAL rendered bytes — skip-and-continue per primitive, never truncated" do
    # a soul doc that alone blows the cap is omitted ENTIRELY (never
    # truncated); the smaller user doc still rides (skip-and-continue)
    huge = String.duplicate("x", 9_000)
    store = identity_store(huge, "small user doc")
    author = Keys.author_for_seed(@operator_seed)
    set = Agent.get(store, & &1)

    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author})

    contents = Enum.map(messages, & &1["content"])
    refute Enum.any?(contents, &String.starts_with?(&1, "Soul: "))
    assert Enum.any?(contents, &(&1 == "User: small user doc"))
    # never truncated: no partial soul note rides
    refute Enum.any?(contents, &String.contains?(&1, "Soul: " <> String.duplicate("x", 100)))
  end

  test "AC1: the identity block is NEVER windowed — window: 0 still renders the block" do
    store = identity_store("soul body", "user body")
    author = Keys.author_for_seed(@operator_seed)
    set = Agent.get(store, & &1)

    messages = Prompt.assemble(set, "session:s1", [], 0, nil, {nil, author})
    contents = Enum.map(messages, & &1["content"])

    assert Enum.any?(contents, &(&1 == "Soul: soul body"))
    assert Enum.any?(contents, &(&1 == "User: user body"))
    # window 0: no conversation turns ride, the block still does
    refute Enum.any?(contents, &(&1 == "hello"))
  end

  test "AC1: the profile-rules segment renders AFTER the three primitives as \"Profile: <name>\\n\" <> rules and counts against the 8192" do
    store = identity_store("soul body", "user body")

    {:ok, profile} =
      Events.profile_set(
        @operator_seed,
        @ts + 2,
        "channel:discord",
        "no politics; answer in character",
        ["identity:soul", "identity:user"],
        [],
        []
      )

    put_wire(store, Wire.envelope(profile))
    author = Keys.author_for_seed(@operator_seed)
    set = Agent.get(store, & &1)

    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {"channel:discord", author})
    contents = Enum.map(messages, & &1["content"])

    assert Enum.at(contents, 1) == "Soul: soul body"
    assert Enum.at(contents, 2) == "User: user body"
    # the profile segment follows the primitives (closed order, then segment)
    assert Enum.at(contents, 3) == "Profile: channel:discord\nno politics; answer in character"
  end

  test "AC1: the nil-seed leg is fail-closed — no operator seed, no identity block, byte-identical to today, no crash" do
    store = identity_store("soul body", "user body")
    set = Agent.get(store, & &1)

    # boot with NO operator seed: the boot context is {nil, nil}
    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, nil})
    contents = Enum.map(messages, & &1["content"])

    refute Enum.any?(contents, &String.starts_with?(&1, "Soul: "))
    refute Enum.any?(contents, &String.starts_with?(&1, "User: "))
    assert hd(messages) == %{"role" => "system", "content" => Prompt.system_prompt()}
  end

  test "AC1 (M4a): a store with NO live identity primitives renders no identity block — byte-identical to today even with an operator author" do
    store = start_store()
    author = Keys.author_for_seed(@operator_seed)
    set = Agent.get(store, & &1)

    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author})
    contents = Enum.map(messages, & &1["content"])

    refute Enum.any?(contents, &String.starts_with?(&1, "Soul: "))
    refute Enum.any?(contents, &String.starts_with?(&1, "User: "))
    refute Enum.any?(contents, &String.starts_with?(&1, "Operator: "))
    assert hd(messages) == %{"role" => "system", "content" => Prompt.system_prompt()}
  end
end
