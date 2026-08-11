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
  alias Rhizomatic.Delta

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
        # T14h: the digest family is minted AFTER the PromptAssembled (the
        # answer path's zero-charge side emission, H1 pre-emission) — the
        # as-of-mint set below the PA excludes it too
        match?(
          %{type: type} when type in ["ResponseDelta", "MessageSent", "StandingDigest", "EpochKeyMaterial"],
          Schema.resolve(claims)
        )
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

  # ====================================================== T14h (always-on)

  defp author, do: Keys.author_for_seed(@operator_seed)

  # the standing fold's inputs: a flagged + epoch-allowed memory canon
  # (StandingFlag + MemoryEntity + the memory-family epoch)
  defp standing_store(entity, content) do
    store = start_store()
    {:ok, mem} = Events.memory_entity(@agent_seed, @ts, entity, content, [])
    put_wire(store, Wire.envelope(mem))
    {:ok, flag} = Events.standing_flag(@agent_seed, @ts + 1, entity)
    put_wire(store, Wire.envelope(flag))
    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 2, [entity])
    put_wire(store, Wire.envelope(epoch))
    store
  end

  test "T14h AC1: the standing block rides EVERY prompt — prompt_text nil AND a zero-overlap prompt render the SAME deterministic bytes" do
    store = standing_store("memory:e1", "the standing fact")
    set = Agent.get(store, & &1)

    # the anti-placebo: a prompt engineered for ZERO digest overlap with the
    # standing entities — the block takes NO prompt_text input (AC1 by
    # construction)
    plain = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author()})
    placebo = Prompt.assemble(set, "session:s1", [], 8, "entirely unrelated question", {nil, author()})

    standing = %{"role" => "system", "content" => "Standing:\n- memory:e1: the standing fact"}
    assert standing in plain
    assert standing in placebo
  end

  test "T14h AC1: the block's slot — system -> identity -> always-on -> memory_notes (the pinned bracket order)" do
    store = identity_store("soul body", "user body")

    {:ok, mem} = Events.memory_entity(@agent_seed, @ts + 10, "memory:e1", "the standing fact", [])
    mem_delta = put_wire(store, Wire.envelope(mem))

    {:ok, flag} = Events.standing_flag(@agent_seed, @ts + 11, "memory:e1")
    put_wire(store, Wire.envelope(flag))

    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 12, ["memory:e1", "memory:n2"])
    put_wire(store, Wire.envelope(epoch))

    # a SECOND entity, NOT standing — its memory note rides the gather AFTER
    # the always-on block (standing wins the dedup for the flagged entity)
    {:ok, mem2} = Events.memory_entity(@agent_seed, @ts + 13, "memory:n2", "a plain note", [])
    n2_delta = put_wire(store, Wire.envelope(mem2))

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, "session:s1", [mem_delta.id, n2_delta.id], 8, nil, {nil, author()})

    assert Enum.map(messages, & &1["content"]) == [
             Prompt.system_prompt(),
             "Soul: soul body",
             "User: user body",
             "Standing:\n- memory:e1: the standing fact",
             "Memory: a plain note"
           ]
  end

  test "T14h AC1: a standing supersede changes the block's bytes — the render is store-derived, never hardcoded" do
    store = standing_store("memory:e1", "original fact")
    set = Agent.get(store, & &1)
    before = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author()})
    assert Enum.any?(before, &(&1["content"] == "Standing:\n- memory:e1: original fact"))

    # the canon supersedes (MemoryEdited): the standing block re-derives the
    # NEW canon content
    {:ok, mem} = Events.memory_entity(@agent_seed, @ts, "memory:e1", "original fact", [])
    {:ok, edited} = Events.memory_edited(@agent_seed, @ts + 20, mem_id(mem), "superseded fact")
    put_wire(store, Wire.envelope(edited))

    set = Agent.get(store, & &1)
    after_messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author()})
    assert Enum.any?(after_messages, &(&1["content"] == "Standing:\n- memory:e1: superseded fact"))
  end

  defp mem_id({claims, _sig}), do: Delta.id_hex(claims)

  test "T14h AC3 (fold door): a channel profile's standing section excludes broader memory — sequential boots, leakage ABSENT" do
    store = start_store()

    # two flagged + broadly-allowed entities
    {:ok, mem1} = Events.memory_entity(@agent_seed, @ts, "memory:pub", "public fact", [])
    put_wire(store, Wire.envelope(mem1))
    {:ok, mem2} = Events.memory_entity(@agent_seed, @ts + 1, "memory:priv", "broader-memory fact", [])
    put_wire(store, Wire.envelope(mem2))
    {:ok, f1} = Events.standing_flag(@agent_seed, @ts + 2, "memory:pub")
    put_wire(store, Wire.envelope(f1))
    {:ok, f2} = Events.standing_flag(@agent_seed, @ts + 3, "memory:priv")
    put_wire(store, Wire.envelope(f2))
    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 4, ["memory:pub", "memory:priv"])
    put_wire(store, Wire.envelope(epoch))

    # the channel profile names NO family: its governing epoch is the derived
    # fail-closed default "memory:profile/channel:discord" (empty-until-seeded)
    {:ok, profile} = Events.profile_set(@operator_seed, @ts + 5, "channel:discord", "rules", [], [], [])
    put_wire(store, Wire.envelope(profile))

    set = Agent.get(store, & &1)

    # boot A (profile-less): the broad memory epoch governs — both ride
    profile_less = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author()})
    assert Enum.any?(profile_less, &(&1["content"] == "Standing:\n- memory:pub: public fact\n- memory:priv: broader-memory fact"))

    # boot B (channel profile): the union over the profile's families
    # governs NOTHING (no family named) — broader memory is excluded from
    # the standing section (born fail-closed, H6)
    channel = Prompt.assemble(set, "session:s1", [], 8, nil, {"channel:discord", author()})
    refute Enum.any?(channel, &(&1["content"] =~ "Standing:"))
  end

  test "T14h AC3 (digest door): the trajectory is session-scoped at mint AND read — a channel profile's block shows ONLY its session's stream" do
    store = start_store()

    # session A's stream (the channel's own session)
    {:ok, rec_a} = Kyber.Events.message_received(String.duplicate("a1", 32), @ts, "msg:a", "chan-1", "session:a", "channel question")
    put_wire(store, Wire.envelope(rec_a))
    {:ok, req_a} = Events.inference_requested(@agent_seed, @ts + 1, "m", "session:a", "conv", "pr", [])
    req_a_id = Delta.id_hex(elem(req_a, 0))
    put_wire(store, Wire.envelope(req_a))
    {:ok, resp_a} = Events.response_delta(@agent_seed, @ts + 2, req_a_id, 0.0, "channel answer", [])
    put_wire(store, Wire.envelope(resp_a))

    # session B's stream (the broader memory's session — must never ride)
    {:ok, rec_b} = Kyber.Events.message_received(String.duplicate("a1", 32), @ts + 10, "msg:b", "chan-1", "session:b", "other session secret")
    put_wire(store, Wire.envelope(rec_b))
    {:ok, req_b} = Events.inference_requested(@agent_seed, @ts + 11, "m", "session:b", "conv", "pr", [])
    req_b_id = Delta.id_hex(elem(req_b, 0))
    put_wire(store, Wire.envelope(req_b))
    {:ok, resp_b} = Events.response_delta(@agent_seed, @ts + 12, req_b_id, 0.0, "other answer", [])
    put_wire(store, Wire.envelope(resp_b))

    # mint the digest for session A through the REAL path
    set = Agent.get(store, & &1)
    :ok = Kyber.Agent.Digest.mint(@agent_seed, fn w -> put_wire(store, w) end, set, "session:a", @ts + 1)

    set = Agent.get(store, & &1)

    # a channel-profile boot over the SAME store: the trajectory section
    # shows session A's asked line ONLY — session B never rides
    messages = Prompt.assemble(set, "session:a", [], 8, nil, {"channel:discord", author()})
    trajectory = Enum.find(Enum.map(messages, & &1["content"]), &String.starts_with?(&1, "Trajectory:"))

    assert trajectory =~ "channel question"
    refute trajectory =~ "other session secret"
    refute trajectory =~ "other answer"
  end

  test "T14h AC4: the THIRD budget is disjoint from the identity block's 8192 — a near-cap identity block and a full standing section both render" do
    store = start_store()

    # identity: a soul doc near the 8192 identity cap
    big_soul = String.duplicate("s", 8_000)
    {:ok, soul} = Events.identity_set(@operator_seed, @ts, "identity:soul", "soul", big_soul)
    put_wire(store, Wire.envelope(soul))

    # standing: a flagged + allowed entity whose section is near the 4096 cap
    {:ok, mem} = Events.memory_entity(@agent_seed, @ts + 1, "memory:e1", String.duplicate("f", 4_000), [])
    put_wire(store, Wire.envelope(mem))
    {:ok, flag} = Events.standing_flag(@agent_seed, @ts + 2, "memory:e1")
    put_wire(store, Wire.envelope(flag))
    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 3, ["memory:e1"])
    put_wire(store, Wire.envelope(epoch))

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, author()})
    contents = Enum.map(messages, & &1["content"])

    # the identity block's 8192 never pools with the standing block's 4096:
    # the soul note (8000+ bytes, within ITS budget) rides AND the standing
    # section (within ITS budget) rides — two disjoint budgets
    assert Enum.any?(contents, &(&1 == "Soul: " <> big_soul))
    assert Enum.any?(contents, &(&1 == "Standing:\n- memory:e1: " <> String.duplicate("f", 4_000)))
  end

  test "T14h M7: a standing line DROPPED by the 4096 skip-whole still gets its memory note — the dedup reads POST-CAP rendered" do
    store = start_store()

    # an entity whose standing line alone would blow the block budget
    {:ok, mem} = Events.memory_entity(@agent_seed, @ts, "memory:huge", String.duplicate("x", 5_000), [])
    huge_delta = put_wire(store, Wire.envelope(mem))
    {:ok, flag} = Events.standing_flag(@agent_seed, @ts + 1, "memory:huge")
    put_wire(store, Wire.envelope(flag))
    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 2, ["memory:huge"])
    put_wire(store, Wire.envelope(epoch))

    set = Agent.get(store, & &1)
    messages = Prompt.assemble(set, "session:s1", [huge_delta.id], 8, nil, {nil, author()})
    contents = Enum.map(messages, & &1["content"])

    # NO standing line (skip-whole dropped it)…
    refute Enum.any?(contents, &String.starts_with?(&1, "Standing:"))
    # …and the entity NEVER vanishes: its memory note still rides (the
    # gather_ids dedup reads the POST-CAP rendered set — M7)
    assert Enum.any?(contents, &(&1 == "Memory: " <> String.duplicate("x", 5_000)))
  end
end
