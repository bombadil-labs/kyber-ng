defmodule Kyber.Agent.EnginePathsTest do
  @moduledoc """
  T14d AC3 — the engine path pins: C1 constructor failure fails HARD (a
  test injects the `{:error, _}` path and asserts the raise, NOT a silent
  skip); C2's "decode failed" arm is witnessed behaviorally (constructor-
  valid garbage-content claim) and the "no content pointer" arm is pinned
  by a STATIC source witness (dead by construction); C3's answered-skip is
  a counted skip with zero new deltas; C4b's post-emit decode-fail raise is
  witnessed through the raw-admission fixture family. Fails-when-absent:
  re-introducing the silent skip passes nothing.

  The raw-admission door (H1/M2): hand-crafted claims cast straight into
  the engine — a `timestamp: "not-a-number"` `InferenceRequested` and a
  `{:string, 123}`-content `MessageReceived` both SURVIVE Schema.resolve
  (the compiler's string-kind check is TAG-only and it merges
  `claims.timestamp` unchecked), so the constructor `{:error, _}` tuple and
  the post-emit decode-fail arm are engine-reachable exactly through this
  door. The raise-vs-skip discrimination lives HERE (the tier-(b) DOWN
  leg), not the review layer.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Rhizomatic.Delta
  alias Kyber.Agent.{Engine, Events, LlmHandler, Prompt}

  @agent_seed String.duplicate("b2", 32)
  @human_seed String.duplicate("a1", 32)
  @ts 1_700_000_000_000.0

  # a deterministic content-only answer — never a network
  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, state) do
      send(state.reply_to, {:llm_request, :ok})

      body =
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => "stub answer"}}
          ]
        })

      {:ok, %{status: 200, body: body}}
    end
  end

  defp llm(http \\ {StubHttp, %{reply_to: self()}}) do
    {:ok, handler} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: http,
        model: "stub-model"
      )

    handler
  end

  # a tiny in-memory store the engine reads through its :store seam; the
  # sink records every emitted wire back into it (what the daemon would do)
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
            llm: llm(Keyword.get(opts, :http, {StubHttp, %{reply_to: self()}})),
            store: fn -> Agent.get(store, & &1) end,
            sink: fn wire ->
              put_wire(store, wire)
              send(test, {:sink, wire})
              {:ok, :persisted}
            end,
            notify: self()
          ],
          opts
        )
      )

    engine
  end

  # the crash witness: monitor + unlink (the engine is start_linked to the
  # test; the raise inside handle_cast would otherwise take the test down),
  # then cast and assert the DOWN reason carries the pinned raise message
  defp assert_engine_raises(engine, cast, message) do
    ref = Process.monitor(engine)
    Process.unlink(engine)
    GenServer.cast(engine, {:delta, cast})

    assert_receive {:DOWN, ^ref, :process, ^engine, {%RuntimeError{message: msg}, _stack}}, 2_000
    assert msg == message
  end

  # ------------------------------------------- the raw-admission fixtures

  # the raw door: hand-crafted claims — never the Events builders (their
  # Delta.validate boundary would refuse a string timestamp / a non-binary
  # string target). The compiler's string-kind check is TAG-only and the
  # typed merge carries claims.timestamp unchecked, so these resolve.
  defp raw_claims(timestamp, pointers) do
    %{
      timestamp: timestamp,
      author: Keys.author_for_seed(@agent_seed),
      pointers: pointers
    }
  end

  defp raw_inference_requested(timestamp, request_id, session_id, prompt_id) do
    raw_claims(timestamp, [
      %{role: "promptRef", target: {:delta, prompt_id, "requested"}},
      %{role: "model", target: {:string, "stub-model"}},
      %{role: "sessionId", target: {:entity, session_id, "inferences"}},
      %{role: "conversationRef", target: {:delta, "conv-ref", "context_of"}},
      %{role: "type", target: {:entity, "InferenceRequested", "instances"}}
    ])
  end

  defp raw_message_received(content_target, session_id, message_id) do
    raw_claims(@ts, [
      %{role: "received", target: {:entity, message_id, "incoming"}},
      %{role: "at", target: {:entity, "channel:c4b", "messages"}},
      %{role: "by", target: {:entity, "ed25519:human", "sent"}},
      %{role: "content", target: content_target},
      %{role: "session", target: {:entity, session_id, "messages"}},
      %{role: "type", target: {:entity, "MessageReceived", "instances"}}
    ])
  end

  # -------------------------------------------------------------- C1

  # C1 tier (a) — the constructor contract: a non-number timestamp is
  # refused at the builder boundary with the pinned error
  test "C1: the constructor contract — a non-number timestamp is {:error, :timestamp_not_a_number}" do
    assert {:error, :timestamp_not_a_number} =
             Events.prompt_assembled(@agent_seed, "not-a-number", "req-1", "session:s1", "{}")

    # the D14 companion: exact integers are coerced at the builder boundary
    # (floats only past the builder), so 123 is admitted — only a non-number
    # fires the pinned error
    assert {:ok, _signed} = Events.prompt_assembled(@agent_seed, 123, "req-1", "session:s1", "{}")
  end

  # C1 tier (b) — the corrupt-delta DOWN leg: a raw-admission
  # InferenceRequested with timestamp "not-a-number" survives Schema.resolve
  # (the compiler merges claims.timestamp unchecked) and fires the
  # constructor-failure arm at engine.ex:217 — which MUST raise
  # "PromptAssembled construction failed: " <> inspect(reason), never
  # silently skip. Restoring the skip FAILS this leg (no DOWN arrives).
  test "C1: constructor failure fails HARD — the corrupt-delta DOWN leg via the raw door" do
    store = start_store()
    engine = start_engine(store)

    request =
      raw_inference_requested("not-a-number", "req-corrupt", "session:s1", "prompt:p1")

    # the raw door's reachability, asserted: the hand-crafted request
    # resolves to a typed InferenceRequested with the string timestamp
    typed = Schema.resolve(request)
    assert %{type: "InferenceRequested", timestamp: "not-a-number"} = typed

    assert_engine_raises(engine, %{id: "req-corrupt", claims: request},
      "PromptAssembled construction failed: :timestamp_not_a_number"
    )

    # the raise happened BEFORE any emission — the prompt was never admitted
    refute_received {:sink, _}
  end

  # -------------------------------------------------------------- C2

  # C2 — the "decode failed" arm, witnessed behaviorally: a constructor-
  # valid garbage-content PromptAssembled verifies (Events builds it) and
  # Prompt.decode rejects it — the replay pre-check then raises, never
  # re-assembles
  test "C2: a stored garbage-content PromptAssembled — Prompt.decode refuses, the engine raises, never re-assembles" do
    # the constructor-valid garbage claim: content is a binary that is not a
    # well-formed canonical message list
    assert {:ok, _decoded} = Prompt.decode(Prompt.canonical([%{"role" => "user", "content" => "ok"}]))
    assert {:error, :malformed} = Prompt.decode("garbage-not-json")

    {:ok, {pa_claims, pa_sig}} =
      Events.prompt_assembled(
        @agent_seed,
        @ts,
        "req-garbage",
        "session:s1",
        "garbage-not-json"
      )

    pa_id = Delta.id_hex(pa_claims)
    store = start_store(%{pa_id => {pa_claims, pa_sig}})
    engine = start_engine(store)

    request = raw_inference_requested(@ts, "req-garbage", "session:s1", "prompt:p1")

    assert_engine_raises(engine, %{id: "req-garbage", claims: request},
      "PromptAssembled store corruption: decode failed"
    )

    # the raise happened in the pre-check — zero emissions, no re-assembly
    refute_received {:sink, _}
  end

  # C2 — the "no content pointer" arm is DEAD BY CONSTRUCTION: the finder
  # requires a resolved PromptAssembled, and resolve-success guarantees the
  # first-match content pointer (the `_other` arm is unreachable). Pinned
  # with a STATIC source witness in the U1 idiom, with the asymmetry vs.
  # the behaviorally-reachable "decode failed" arm stated here.
  test "C2: the no-content-pointer arm is pinned by a static source witness (dead by construction)" do
    source = File.read!("lib/kyber/agent/engine.ex")

    # the arm's exact spelling — deleting the arm fails this leg
    assert source =~ ~s(raise "PromptAssembled store corruption: no content pointer")

    # the dead-by-construction asymmetry: the finder (engine.ex:250-255)
    # requires match?(%{type: "PromptAssembled"}, Schema.resolve(claims)),
    # and resolve rejects every shape that could reach the _other arm
    # (missing content / non-string tag / duplicate roles); resolve-success
    # guarantees the first-match pointer/2 returns {:string, _} at
    # engine.ex:257-258. A behavioral leg would be a placebo (it would pass
    # with the arm deleted) — the source witness is the mandated form.
    assert source =~ ~s|match?(%{type: "PromptAssembled"}, Schema.resolve(claims))|
  end

  # -------------------------------------------------------------- C3

  # C3 — answered-skip idempotence: a re-fired answered request is a
  # COUNTED skip — zero new deltas, zero model calls
  test "C3: an answered request re-fires as a counted skip with zero new deltas" do
    store = start_store()
    engine = start_engine(store)

    # the answered request: a ResponseDelta pointing at it already lives in
    # the store
    {:ok, {resp_claims, resp_sig}} =
      Events.response_delta(@agent_seed, @ts, "req-answered", 0.0, "already answered", [])

    resp_id = Delta.id_hex(resp_claims)
    Agent.update(store, &Map.put(&1, resp_id, {resp_claims, resp_sig}))

    request = raw_inference_requested(@ts, "req-answered", "session:s1", "prompt:p1")

    assert Engine.handler(engine).([%{id: "req-answered", claims: request}]) == []
    assert %{skipped: 1, answered: 0} = Engine.status(engine)

    # zero new emissions and zero model calls
    refute_received {:sink, _}
    refute_received {:llm_request, _}
  end

  # -------------------------------------------------------------- C4b

  # C4b (fold P2) — the post-emit decode-fail raise: "canonical does not
  # decode" (engine.ex:213-214). Reachable ONLY through the raw-admission
  # fixture: a MessageReceived whose content pointer is STRING-TAGGED but
  # NON-binary ({:string, 123}) — the compiler's string-kind check is
  # tag-only, so it resolves, and context_builder's turn/3 carries the
  # payload with no binary guard — the canonical then ENCODES (integer
  # content is JSON-encodable) and decode REJECTS (content must be binary).
  test "C4b: a raw {:string, 123} MessageReceived fires the canonical-does-not-decode raise" do
    # the fixture survives Schema.resolve — the tag-only string-kind check
    msg = raw_message_received({:string, 123}, "session:c4b", "message:c4b")
    assert %{type: "MessageReceived", content: 123} = Schema.resolve(msg)

    msg_id = "message:c4b"
    store = start_store(%{msg_id => {msg, "raw"}})
    engine = start_engine(store)

    request =
      raw_inference_requested(@ts, "req-c4b", "session:c4b", "prompt:c4b")

    # the PromptAssembled IS emitted (encode succeeds), then decode rejects —
    # the raise is post-emit, the third corruption arm
    assert_engine_raises(engine, %{id: "req-c4b", claims: request},
      "PromptAssembled store corruption: canonical does not decode"
    )
  end
  # -------------------------------------------------------------- E1 (T14e)

  # the tool-calling model stub (the E1 legs): on the FIRST call there is no
  # tool message in context, so the model asks for the echo tool; on every
  # later call it answers from whatever tool message it sees — the refusal
  # loop ("refused: ...") and the real-result flow both land here, so the
  # test can assert exactly what the model's view carried
  defmodule ToolStubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      decoded = JSON.decode!(body)
      send(state.reply_to, {:llm_request, decoded})

      message =
        case Enum.find(decoded["messages"], &(&1["role"] == "tool")) do
          %{"content" => content} ->
            %{"role" => "assistant", "content" => "The tool said: " <> content}

          nil ->
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_e1",
                  "type" => "function",
                  "function" => %{"name" => "tool_echo", "arguments" => "{\"args\":\"e1-ping\"}"}
                }
              ]
            }
        end

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

  # receive sink wires until one of the wanted type arrives (earlier wires —
  # the PromptAssembled — are consumed and discarded)
  defp sink_typed(type) do
    assert_receive {:sink, wire}, 2_000
    {:ok, delta} = Store.verify(wire)

    case Schema.resolve(delta.claims) do
      %{type: ^type} = typed -> {typed, delta}
      _other -> sink_typed(type)
    end
  end

  # the shared E1 fixture: an InferenceRequested that makes the model ask for
  # the echo tool — the engine emits the ToolCall and keeps the call pending;
  # returns {engine, call_delta}
  defp tool_chain(store, request_id) do
    engine =
      start_engine(store, http: {ToolStubHttp, %{reply_to: self()}})

    request = raw_inference_requested(@ts, request_id, "session:s1", "prompt:p1")
    assert Engine.handler(engine).([%{id: request_id, claims: request}]) == []

    {_call, call_delta} = sink_typed("ToolCall")
    assert_receive {:llm_request, _}
    {engine, call_delta}
  end

  # E1a — the M5 decided-allow pass-through: a store containing a
  # GateDecision claim with verdict "allow" for a pending call routes to
  # `_other -> state` — NO fabricated refusal reaches the model (no re-plan
  # call, no emitted wire) and the call STAYS pending for its real
  # ToolResult. Restoring the atom guard (`!= :allow`) fails this leg: the
  # wire verdict is a STRING, so every GateDecision would fabricate a
  # refusal.
  test "E1a: decided-allow pass-through — an allow GateDecision emits NO refusal wire" do
    store = start_store(%{})
    {engine, call_delta} = tool_chain(store, "req-e1a")

    {:ok, {claims, sig}} =
      Events.gate_decision(@agent_seed, @ts + 1, call_delta.id, "allow", "test_policy")

    gate_delta = put_wire(store, Wire.envelope({claims, sig}))

    assert Engine.handler(engine).([gate_delta]) == []

    # the sync barrier: status/1 is a call that serializes behind the cast —
    # the GateDecision has been processed by now; the call is still pending
    assert %{pending: 1, tool_calls: 1} = Engine.status(engine)

    # no fabricated refusal: no re-plan model call, no emitted wire
    refute_received {:llm_request, _}
    refute_received {:sink, _}
  end

  # E1b — decided-refuse WITH a reason: the refusal routes back to the model
  # (the refusal loop) carrying the pinned reason
  test "E1b: decided-refuse with a reason — the refusal carries the reason" do
    store = start_store(%{})
    {engine, call_delta} = tool_chain(store, "req-e1b")

    {:ok, {claims, sig}} =
      Events.gate_decision(
        @agent_seed,
        @ts + 1,
        call_delta.id,
        "refuse",
        "test_policy",
        "the policy says no"
      )

    gate_delta = put_wire(store, Wire.envelope({claims, sig}))

    assert Engine.handler(engine).([gate_delta]) == []

    # the model re-plans and its view carries the refused-call tool message
    # with the pinned reason
    assert_receive {:llm_request, body}, 2_000

    assert %{"content" => "refused: the policy says no"} =
             Enum.find(body["messages"], &(&1["role"] == "tool"))

    {response, _} = sink_typed("ResponseDelta")
    assert response.content == "The tool said: refused: the policy says no"
    assert response.requestRef == {:delta, "req-e1b", "answered"}
  end

  # E1c — decided-refuse with NO reason: the reason falls back to the wire
  # verdict spelling ("refuse") — no crash. Restoring `Atom.to_string`
  # crashes the engine on the string verdict (ArgumentError) and no re-plan
  # arrives: this leg fails.
  test "E1c: decided-refuse without a reason — reason falls back to the verdict spelling" do
    store = start_store(%{})
    {engine, call_delta} = tool_chain(store, "req-e1c")

    {:ok, {claims, sig}} =
      Events.gate_decision(@agent_seed, @ts + 1, call_delta.id, "refuse", "test_policy")

    gate_delta = put_wire(store, Wire.envelope({claims, sig}))

    assert Engine.handler(engine).([gate_delta]) == []

    assert_receive {:llm_request, body}, 2_000

    assert %{"content" => "refused: refuse"} =
             Enum.find(body["messages"], &(&1["role"] == "tool"))

    {response, _} = sink_typed("ResponseDelta")
    assert response.content == "The tool said: refused: refuse"
  end

  # E1d — decided-allow + the matching ToolResult: after the pass-through,
  # the REAL ToolResult claim still flows to the model's view (the semantic
  # degradation carry closed — the model sees the result, not a refusal)
  test "E1d: decided-allow + matching ToolResult — the real result flows to the model's view" do
    store = start_store(%{})
    {engine, call_delta} = tool_chain(store, "req-e1d")

    {:ok, {claims, sig}} =
      Events.gate_decision(@agent_seed, @ts + 1, call_delta.id, "allow", "test_policy")

    gate_delta = put_wire(store, Wire.envelope({claims, sig}))

    assert Engine.handler(engine).([gate_delta]) == []
    # the pass-through keeps the call pending — no fabricated refusal
    assert %{pending: 1} = Engine.status(engine)

    {:ok, {tr_claims, tr_sig}} =
      Events.tool_result(@agent_seed, @ts + 2, call_delta.id, "the-real-result", "ok")

    tr_delta = put_wire(store, Wire.envelope({tr_claims, tr_sig}))

    assert Engine.handler(engine).([tr_delta]) == []

    # the model's view carries the REAL result, not a fabricated refusal
    assert_receive {:llm_request, body}, 2_000

    assert %{"content" => "the-real-result"} =
             Enum.find(body["messages"], &(&1["role"] == "tool"))

    {response, _} = sink_typed("ResponseDelta")
    assert response.content == "The tool said: the-real-result"
    assert response.requestRef == {:delta, "req-e1d", "answered"}
  end
end
