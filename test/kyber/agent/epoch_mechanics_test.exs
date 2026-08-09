defmodule Kyber.Agent.EpochMechanicsTest do
  @moduledoc """
  T14d AC4 — store/epoch mechanics: D1 merge-is-union on identical double-
  emission (one claim); D2 retraction-is-negation (a retracted epoch is not
  current — the previous unretracted epoch revives); D3 fork-detection
  precision (any n >= 2 live heads is `{:error, :forked}` — count-
  insensitive, no winner-picking, same tuple for 2, 3, 4+ heads); D4 the
  concurrency bound (cap 1 STRUCTURAL — one handle_cast, synchronous
  LlmHandler.chat/3, zero Task/spawn — at-cap requests queue in commit
  order, witnessed by the blocking-stub leg + the notify seam's
  {:answered, request_id} ORDER). Fails-when-absent: weakening fork
  detection or re-introducing concurrency fails the suite.
  """
  use ExUnit.Case, async: true

  alias Kyber.{DeltaSet, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Engine, Events, LlmHandler, Policy, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b7", 32)
  @ts 1_700_000_000_000.0

  defp memory_epoch(allow_entities, opts \\ []) do
    ts = Keyword.get(opts, :ts, @ts)
    supersedes = Keyword.get(opts, :supersedes)

    {:ok, {claims, sig}} = Events.memory_policy(@agent_seed, ts, allow_entities, supersedes)
    {Delta.id_hex(claims), {claims, sig}}
  end

  # a hand-crafted negation claim (retraction-is-negation): any delta whose
  # pointer set carries a "negates" role makes the target inert
  defp negates(target_id, ts) do
    claims = %{
      timestamp: ts,
      author: Keys.author_for_seed(@agent_seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, claims} = Delta.validate(claims)
    {:ok, sig} = Keys.sign(claims, @agent_seed)
    {Delta.id_hex(claims), {claims, sig}}
  end

  # -------------------------------------------------------------- D1

  # D1 — merge-is-union on identical double-emission: the same wire through
  # the pure door twice yields exactly ONE claim; a doubled epoch claim is
  # one head, never a fork
  test "D1: identical double-emission merges to exactly one claim" do
    {:ok, signed} = Events.memory_policy(@agent_seed, @ts, ["e1"])
    wire = Wire.envelope(signed)

    {:ok, set1} = Store.admit(wire, DeltaSet.new())
    assert map_size(set1) == 1

    {:ok, set2} = Store.admit(wire, set1)
    assert map_size(set2) == 1

    # the policy sees one head — the doubled epoch is not a fork
    assert {:ok, %{allow_entities: ["e1"]}} = Policy.memory_epoch(set2)
  end

  # -------------------------------------------------------------- D2

  # D2 — retraction-is-negation: a retracted epoch is not current; the
  # previous unretracted epoch REVIVES (history is never rewritten, the
  # store only learns)
  test "D2: retracting the current epoch revives the previous unretracted one" do
    {e1_id, e1} = memory_epoch(["e1"])
    {e2_id, e2} = memory_epoch(["e2"], ts: @ts + 1, supersedes: e1_id)
    set = %{e1_id => e1, e2_id => e2}

    assert {:ok, %{id: ^e2_id}} = Policy.memory_epoch(set)

    {neg_id, neg} = negates(e2_id, @ts + 2)
    set = Map.put(set, neg_id, neg)

    # e2 is inert — e1 (unsuperseded, unretracted) is current again
    assert {:ok, %{id: ^e1_id, allow_entities: ["e1"]}} = Policy.memory_epoch(set)
  end

  test "D2: a retracted-only epoch leaves the family ungoverned" do
    {e1_id, e1} = memory_epoch(["e1"])
    {neg_id, neg} = negates(e1_id, @ts + 1)
    set = %{e1_id => e1, neg_id => neg}

    assert Policy.memory_epoch(set) == :none
  end

  # -------------------------------------------------------------- D3

  # D3 — fork detection precision: exactly two live heads is {:error,
  # :forked}; THREE+ live heads is the SAME tuple — count-insensitive, no
  # distinct error, no winner-picking (policy.ex:140's catch-all is
  # normative for any n >= 2)
  test "D3: fork detection is count-insensitive — 2, 3 and 4 live heads all read {:error, :forked}" do
    {a_id, a} = memory_epoch(["a"])
    {b_id, b} = memory_epoch(["b"], ts: @ts + 1)
    {c_id, c} = memory_epoch(["c"], ts: @ts + 2)
    {d_id, d} = memory_epoch(["d"], ts: @ts + 3)

    assert Policy.memory_epoch(%{a_id => a, b_id => b}) == {:error, :forked}
    assert Policy.memory_epoch(%{a_id => a, b_id => b, c_id => c}) == {:error, :forked}
    assert Policy.memory_epoch(%{a_id => a, b_id => b, c_id => c, d_id => d}) == {:error, :forked}
  end

  test "D3: memory.read under THREE live heads — the same forked refusal, refuse-before-resolve" do
    {a_id, a} = memory_epoch(["e1"])
    {b_id, b} = memory_epoch(["e2"], ts: @ts + 1)
    {c_id, c} = memory_epoch(["e3"], ts: @ts + 2)
    set = %{a_id => a, b_id => b, c_id => c}

    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: ToolExecutor.memory_tools(fn -> set end),
        gate: Gate.new(default: :allow),
        store: fn -> set end
      )

    {:ok, signed} = Events.tool_call(@agent_seed, @ts + 3, "memory.read",
      JSON.encode!(%{"entity" => "e1"}), String.duplicate("cd", 32))

    {:ok, call} = Store.verify(Wire.envelope(signed))

    assert [refusal_wire] = handler.([call])
    {:ok, refusal} = Store.verify(refusal_wire)
    resolved = Schema.resolve(refusal.claims)
    assert resolved.verdict == "refuse"
    assert resolved.policy == "memory_policy"
    assert resolved.reason == "memory_policy: epoch forked (fail closed)"
    assert resolved.policy_epoch == nil
  end

  # -------------------------------------------------------------- D4

  # D4 — the concurrency bound is STRUCTURAL: one handle_cast, synchronous
  # LlmHandler.chat/3 inside the cast, zero Task/spawn in engine.ex. NO new
  # literal, NO new GateDecision surface. The static witness pins the
  # structure; the blocking-stub leg pins the behavior.
  test "D4: cap 1 structural — one handle_cast, zero Task/spawn in engine.ex (static witness)" do
    source = File.read!("lib/kyber/agent/engine.ex")

    assert length(Regex.scan(~r/def handle_cast/, source)) == 1
    refute Regex.match?(~r/(Task\.|spawn\()/, source)
  end

  # the blocking stub: chat runs INSIDE the engine process (synchronous
  # handle_cast), so `receive :release` reads the ENGINE's mailbox —
  # sanctioned synchronization, released by send(engine, :release), no
  # Process.sleep. If chat were async, the second request would be
  # processed (and its {:llm_request, _} emitted) BEFORE the release.
  defmodule BlockingStubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, state) do
      send(state.reply_to, {:llm_request, :blocked})

      receive do
        :release -> :ok
      end

      body =
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => "unblocked"}}
          ]
        })

      {:ok, %{status: 200, body: body}}
    end
  end

  defp blocking_llm do
    {:ok, handler} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {BlockingStubHttp, %{reply_to: self()}},
        model: "stub-model"
      )

    handler
  end

  defp start_store(initial \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp start_engine(store) do
    test = self()

    {:ok, engine} =
      Engine.start_link(
        name: nil,
        llm: blocking_llm(),
        store: fn -> Agent.get(store, & &1) end,
        sink: fn wire ->
          {:ok, delta} = Store.verify(wire)
          Agent.update(store, &Map.put(&1, wire["id"], {delta.claims, wire["sig"]}))
          send(test, {:sink, wire})
          {:ok, :persisted}
        end,
        notify: self()
      )

    engine
  end

  defp request_claims(request_id, ts) do
    {:ok, {claims, sig}} =
      Events.inference_requested(
        @agent_seed,
        ts,
        "stub-model",
        "session:s1",
        "conv-ref",
        "prompt:" <> request_id,
        []
      )

    {request_id, %{id: request_id, claims: claims}}
  end

  # D4 — at-cap QUEUE in commit order: exactly one {:llm_request, _} before
  # the release (req-B queued in the mailbox, never refused, never dropped),
  # then the notify seam's {:answered, request_id} ORDER — req-A answered
  # before req-B (the discriminating channel: two requests over an empty
  # store assemble identical bodies, so body inspection cannot order them).
  test "D4: at cap the second request queues — commit order via the {:answered, request_id} seam" do
    store = start_store()
    engine = start_engine(store)

    {req_a_id, req_a} = request_claims("req-a", @ts)
    {req_b_id, req_b} = request_claims("req-b", @ts + 1)

    GenServer.cast(engine, {:delta, req_a})
    GenServer.cast(engine, {:delta, req_b})

    # req-A's chat is in flight; req-B is queued — exactly one model call
    assert_receive {:llm_request, :blocked}, 2_000
    refute_receive {:llm_request, :blocked}, 100

    # release req-A — it completes and answers BEFORE req-B starts
    send(engine, :release)
    assert_receive {:engine, {:answered, ^req_a_id}}, 2_000

    # only now does req-B's chat start
    assert_receive {:llm_request, :blocked}, 2_000
    send(engine, :release)
    assert_receive {:engine, {:answered, ^req_b_id}}, 2_000

    # both requests answered, in commit order, never dropped
    assert %{answered: 2} = Engine.status(engine)
  end
end
