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
            llm: llm(),
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
end
