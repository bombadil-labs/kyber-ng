defmodule Kyber.Agent.StandingDigestTest do
  @moduledoc """
  T14h N5/H4/H7/AC5 — the StandingDigest family: genesis kinds + the door,
  the zero-charge trigger-ts mint (change-guard vs the last MINTED head,
  live or dead; empty derivation mints nothing; construction errors
  SWALLOW — M9), the no-rollback retraction (`:none` until the next mint),
  the flag-liveness C/D legs (author-blind, M6), and the AC5 two-boot
  determinism witness under BOTH sinks (the capture sink AND `Daemon.emit`)
  — identical `StandingDigest` ids and identical `PromptAssembled` ids.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Digest, Engine, Events, LlmHandler, MemoryPort, Prompt, Standing}
  alias Kyber.Schema.Genesis
  alias Rhizomatic.Delta

  @human_seed String.duplicate("a1", 32)
  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)
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
            end
          ],
          opts
        )
      )

    engine
  end

  defp ingest_received(store, ts, msg_id, content, session \\ "session:s1") do
    {:ok, signed} = Kyber.Events.message_received(@human_seed, ts, msg_id, "chan-1", session, content)
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

  defp id64(hex), do: String.duplicate(hex, 8)

  defp raw_negation(target_id, opts \\ []) do
    seed = Keyword.get(opts, :seed, @operator_seed)
    ts = Keyword.get(opts, :ts, @ts + 99)

    claims = %{
      timestamp: ts,
      author: Keys.author_for_seed(seed),
      pointers: [%{role: "negates", target: {:delta, target_id, "retracted"}}]
    }

    {:ok, sig} = Keys.sign(claims, seed)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp admit(store, {id, {claims, sig}}) do
    put_wire(store, Wire.envelope({claims, sig}))
    id
  end

  # ---------------------------------------------------------- genesis kinds

  test "N5: the three T14h kinds ride the compiled genesis set with the pinned field shapes" do
    schemas = Genesis.compiled().schemas

    assert %{fields: sd_fields} = schemas["StandingDigest"]
    assert sd_fields["sessionId"].kind == :entity
    assert sd_fields["sessionId"].arity == :one
    assert sd_fields["content"].kind == :string
    assert sd_fields["content"].arity == :one
    assert sd_fields["covers"].kind == :delta
    assert sd_fields["covers"].arity == :many

    assert %{fields: sf_fields} = schemas["StandingFlag"]
    assert sf_fields["standing"].kind == :entity
    assert sf_fields["standing"].arity == :one

    assert %{fields: km_fields} = schemas["EpochKeyMaterial"]
    assert km_fields["profile"].kind == :string
    assert km_fields["roster"].kind == :string
    assert km_fields["head"].kind == :delta
    assert km_fields["head"].arity == :maybe

    # PromptAssembled: the optional replayKey delta role (N5)
    assert %{fields: pa_fields} = schemas["PromptAssembled"]
    assert pa_fields["replayKey"].kind == :delta
    assert pa_fields["replayKey"].arity == :maybe
  end

  test "N5: the builders admit through the door and resolve typed — the folds' input is typed, never raw" do
    {:ok, signed} = Events.standing_digest(@agent_seed, @ts, "session:s1", "asked: hi", [id64("11")])
    {claims, _sig} = signed
    wire = Wire.envelope(signed)
    assert {:ok, %{id: _id, claims: ^claims}} = Store.verify(wire)
    assert %{type: "StandingDigest", sessionId: {:entity, "session:s1", "digests"}, content: "asked: hi"} = Schema.resolve(claims)
    assert Schema.resolve(claims).covers == [{:delta, id64("11"), "covered"}]

    {:ok, {flag_claims, _}} = Events.standing_flag(@agent_seed, @ts, "memory:e1")
    assert %{type: "StandingFlag", standing: {:entity, "memory:e1", "standing"}} = Schema.resolve(flag_claims)

    {:ok, {km_claims, _}} = Events.epoch_key_material(@agent_seed, @ts, "channel:x", "[]", id64("99"))
    assert %{type: "EpochKeyMaterial", profile: "channel:x", roster: "[]"} = Schema.resolve(km_claims)
    assert Schema.resolve(km_claims).head == {:delta, id64("99"), "declared"}
  end

  test "N5 (the T14f H5 lesson): a pre-evolution binary admits all three kinds as :raw — never crashes" do
    # the pre-evolution compiled set: the current genesis MINUS the three
    # new kinds (and the PA replayKey field — a pre-evolution PA validates
    # fine without it)
    pre = %{
      schemas: Map.drop(Genesis.compiled().schemas, ["StandingDigest", "StandingFlag", "EpochKeyMaterial"]),
      hyperschemas: Genesis.compiled().hyperschemas
    }

    {:ok, {digest_claims, _}} = Events.standing_digest(@agent_seed, @ts, "session:s1", "asked: hi", [])
    {:ok, {flag_claims, _}} = Events.standing_flag(@agent_seed, @ts, "memory:e1")
    {:ok, {km_claims, _}} = Events.epoch_key_material(@agent_seed, @ts, "channel:x", "[]", nil)

    assert {:ok, :raw} = Kyber.Schema.Compiler.validate(digest_claims, pre.schemas)
    assert {:ok, :raw} = Kyber.Schema.Compiler.validate(flag_claims, pre.schemas)
    assert {:ok, :raw} = Kyber.Schema.Compiler.validate(km_claims, pre.schemas)
  end

  # ---------------------------------------------------------- the mint path

  test "H7: the answer path mints ONE StandingDigest per content-changing answer — trigger ts, session-scoped, covers the rendered deltas" do
    store = start_store()
    engine = start_engine(store)

    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine, prompt)
    _ = request

    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {digest, digest_delta} = sink_typed("StandingDigest")

    # the mint claims the TRIGGERING request's claims.timestamp — never
    # wall-clock (the just-emitted ResponseDelta's now() is NOT the mint ts)
    assert digest_delta.claims.timestamp == @ts
    assert digest.sessionId == {:entity, "session:s1", "digests"}
    assert digest.content == "asked: hello"

    set = Agent.get(store, & &1)

    # covers = the POST-CAP rendered deltas (M8) — exactly the asked line's
    # MessageReceived (the typed many-role resolves to TAGGED tuples)
    assert length(digest.covers) == 1
    assert Enum.any?(set, fn {id, {claims, _sig}} ->
             Enum.any?(digest.covers, &match?({:delta, ^id, _ctx}, &1)) and
               match?(%{type: "MessageReceived"}, Schema.resolve(claims))
           end)

    # ZERO-CHARGE (H7): no GateDecision minted, no turn attribution (the
    # digest has no requestRef), the engine status shows exactly the answer
    refute Enum.any?(set, fn {_id, {claims, _sig}} ->
      match?(%{type: "GateDecision"}, Schema.resolve(claims))
    end)
    refute Enum.any?(digest_delta.claims.pointers, &(&1.role == "requestRef"))
    assert %{answered: 1} = Engine.status(engine)
  end

  test "H7: the answer path mints ONE digest per content-changing answer — a new turn's asked line changes the derivation" do
    store = start_store()
    engine = start_engine(store)

    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request_inference(store, engine, prompt)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {d1, _} = sink_typed("StandingDigest")

    prompt2 = ingest_received(store, @ts + 10, "msg-2", "hello again")
    request_inference(store, engine, prompt2)
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {d2, _} = sink_typed("StandingDigest")

    # each content-changing answer mints; the second digest folds BOTH asked
    # lines + the first turn's answered line (chronological — the entry set
    # holds the first ResponseDelta) and its covers grow
    assert d1.content == "asked: hello"
    assert d2.content == "asked: hello\nasked: hello again\nanswered: stub answer"
    assert length(d2.covers) == 3
  end

  test "H7: the change-guard skips when the derivation is IDENTICAL to the last minted head" do
    store = start_store()
    set = Agent.get(store, & &1)

    # seed a digest whose content matches what the next answer would derive
    {:ok, first} = Events.standing_digest(@agent_seed, @ts, "session:s1", "asked: hello", [id64("11")])
    put_wire(store, Wire.envelope(first))

    # the digest mint derives "asked: hello" == the seeded head -> no mint
    :ok = Digest.mint(@agent_seed, fn w -> put_wire(store, w) end, set, "session:s1", @ts)
    assert map_size(Agent.get(store, & &1)) == 1

    # a changed derivation mints fresh
    ingest_received(store, @ts + 10, "msg-2", "different", "session:s1")
    set = Agent.get(store, & &1)
    :ok = Digest.mint(@agent_seed, fn w -> put_wire(store, w) end, set, "session:s1", @ts + 10)
    set = Agent.get(store, & &1)
    digests = for {_id, {claims, _sig}} <- set, match?(%{type: "StandingDigest"}, Schema.resolve(claims)), do: claims
    assert length(digests) == 2
  end

  test "H7: an empty derivation mints NOTHING — the enforcement point is the minter" do
    store = start_store()
    set = Agent.get(store, & &1)
    :ok = Digest.mint(@agent_seed, fn _w -> flunk("no mint on empty derivation") end, set, "session:s1", @ts)
    assert map_size(Agent.get(store, & &1)) == 0
  end

  test "M9: the construction-error arm SWALLOWS — a non-number trigger ts mints nothing and never raises" do
    store = start_store()
    ingest_received(store, @ts, "msg-1", "hello")
    set = Agent.get(store, & &1)
    :ok = Digest.mint(@agent_seed, fn _w -> flunk("no mint on bad ts") end, set, "session:s1", "not-a-number")
    assert map_size(Agent.get(store, & &1)) == 1
  end

  # ------------------------------------------------- retraction (no-rollback)

  test "H4/G4: a retracted digest head is :none — NO-ROLLBACK, even with an older LIVE head in the stream" do
    store = start_store()
    session = "session:retract"

    {:ok, older} = Events.standing_digest(@agent_seed, @ts, session, "older digest", [id64("11")])
    put_wire(store, Wire.envelope(older))
    {:ok, newer} = Events.standing_digest(@agent_seed, @ts + 1, session, "newer digest", [id64("22")])
    {newer_claims, _} = newer
    newer_id = Delta.id_hex(newer_claims)
    put_wire(store, Wire.envelope(newer))

    set = Agent.get(store, & &1)
    assert {:ok, "newer digest"} = Digest.head(set, session)

    # retract the HEAD (the max {ts, id} claim): the fold is :none — the
    # older LIVE head is never re-exposed (fallback-to-previous rejected)
    admit(store, raw_negation(newer_id))
    set = Agent.get(store, & &1)
    assert :none = Digest.head(set, session)

    # restore = negate the negation: the head is live again
    {neg_id, _neg} = raw_negation(newer_id)
    admit(store, raw_negation(neg_id, ts: @ts + 3))
    set = Agent.get(store, & &1)
    assert {:ok, "newer digest"} = Digest.head(set, session)
  end

  test "H4: flag liveness C/D — a retracted flag drops the entity; a re-flag rides; a rotation drops a live-flagged entity (M7 order)" do
    store = start_store()
    {:ok, mem1} = Events.memory_entity(@agent_seed, @ts, "memory:e1", "fact one", [])
    put_wire(store, Wire.envelope(mem1))
    {:ok, mem2} = Events.memory_entity(@agent_seed, @ts + 1, "memory:e2", "fact two", [])
    put_wire(store, Wire.envelope(mem2))
    {:ok, flag1} = Events.standing_flag(@agent_seed, @ts + 2, "memory:e1")
    flag1_id = Wire.envelope(flag1)["id"]
    put_wire(store, Wire.envelope(flag1))
    {:ok, flag2} = Events.standing_flag(@agent_seed, @ts + 3, "memory:e2")
    put_wire(store, Wire.envelope(flag2))
    {:ok, {epoch_claims, epoch_sig}} = Events.memory_policy(@operator_seed, @ts + 4, ["memory:e1", "memory:e2"])
    epoch_id = Delta.id_hex(epoch_claims)
    put_wire(store, Wire.envelope({epoch_claims, epoch_sig}))

    set = Agent.get(store, & &1)
    assert Enum.map(Standing.fold(set, nil), & &1.entity) == ["memory:e1", "memory:e2"]

    # C: retract e1's flag -> NOT standing (author-blind — the operator's
    # hand-rolled negation counts, M6)
    admit(store, raw_negation(flag1_id))
    set = Agent.get(store, & &1)
    assert Enum.map(Standing.fold(set, nil), & &1.entity) == ["memory:e2"]

    # D: re-flag after removal rides with no special case
    {:ok, flag1b} = Events.standing_flag(@agent_seed, @ts + 6, "memory:e1")
    put_wire(store, Wire.envelope(flag1b))
    set = Agent.get(store, & &1)
    assert Enum.map(Standing.fold(set, nil), & &1.entity) == ["memory:e1", "memory:e2"]

    # rotation: a live-flagged entity leaves the epoch allowlist -> not
    # standing (visibility != salience)
    {:ok, epoch2} = Events.memory_policy(@operator_seed, @ts + 7, ["memory:e1"], epoch_id)
    put_wire(store, Wire.envelope(epoch2))
    set = Agent.get(store, & &1)
    assert Enum.map(Standing.fold(set, nil), & &1.entity) == ["memory:e1"]
  end

  test "M7: standing renders {ts, id} ASCENDING over the canon heads — never resolve_set's entity-id sort" do
    store = start_store()

    # flagged in REVERSE canon order: e2's canon is OLDER than e1's, so the
    # fold renders e2 first despite the flag order
    {:ok, mem1} = Events.memory_entity(@agent_seed, @ts + 10, "memory:e1", "fact one", [])
    put_wire(store, Wire.envelope(mem1))
    {:ok, mem2} = Events.memory_entity(@agent_seed, @ts, "memory:e2", "fact two", [])
    put_wire(store, Wire.envelope(mem2))
    {:ok, flag1} = Events.standing_flag(@agent_seed, @ts + 11, "memory:e1")
    put_wire(store, Wire.envelope(flag1))
    {:ok, flag2} = Events.standing_flag(@agent_seed, @ts + 12, "memory:e2")
    put_wire(store, Wire.envelope(flag2))
    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 13, ["memory:e1", "memory:e2"])
    put_wire(store, Wire.envelope(epoch))

    set = Agent.get(store, & &1)
    assert Enum.map(Standing.fold(set, nil), & &1.entity) == ["memory:e2", "memory:e1"]

    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, Keys.author_for_seed(@operator_seed)})
    standing = Enum.find(Enum.map(messages, & &1["content"]), &String.starts_with?(&1, "Standing:"))

    assert standing == "Standing:\n- memory:e2: fact two\n- memory:e1: fact one"
  end

  test "H6: the standing section is born FAIL-CLOSED — :none and {:error, :forked} render nothing" do
    store = start_store()
    {:ok, mem} = Events.memory_entity(@agent_seed, @ts, "memory:e1", "fact one", [])
    put_wire(store, Wire.envelope(mem))
    {:ok, flag} = Events.standing_flag(@agent_seed, @ts + 1, "memory:e1")
    put_wire(store, Wire.envelope(flag))

    # no memory epoch at all -> :none -> no standing lines, profile or not
    set = Agent.get(store, & &1)
    assert Standing.fold(set, nil) == []

    messages = Prompt.assemble(set, "session:s1", [], 8, nil, {nil, Keys.author_for_seed(@operator_seed)})
    refute Enum.any?(messages, &(&1["content"] =~ "Standing:"))

    # a FORKED memory epoch (two live heads) -> no standing lines
    {:ok, e1} = Events.memory_policy(@operator_seed, @ts + 2, ["memory:e1"])
    put_wire(store, Wire.envelope(e1))
    {:ok, e2} = Events.memory_policy(@operator_seed, @ts + 3, ["memory:e1"])
    put_wire(store, Wire.envelope(e2))

    set = Agent.get(store, & &1)
    assert {:error, :forked} = Kyber.Agent.Policy.memory_epoch(set)
    assert Standing.fold(set, nil) == []
  end

  # -------------------------------------------------- two-boot determinism

  test "AC5: two sequential cold boots (capture sink) — IDENTICAL StandingDigest ids AND PromptAssembled ids" do
    first = capture_boot()
    second = capture_boot()

    assert first.digest_id == second.digest_id
    assert first.pa_id == second.pa_id
    assert first.digest_ts == @ts
    assert first.pa_ts == @ts
  end

  defp capture_boot do
    store = start_store()
    engine = start_engine(store)
    prompt = ingest_received(store, @ts, "msg:det", "deterministic prompt")
    request = request_inference(store, engine, prompt)
    _ = request

    {_pa, pa_delta} = sink_typed("PromptAssembled")
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    {_digest, digest_delta} = sink_typed("StandingDigest")

    %{
      digest_id: digest_delta.id,
      pa_id: pa_delta.id,
      digest_ts: digest_delta.claims.timestamp,
      pa_ts: pa_delta.claims.timestamp
    }
  end

  # ------------------------------------------- the Daemon.emit leg (H1/AC5)

  test "AC5 (H1): the identical-digest-ids witness is sink-implementation-independent — the Daemon.emit leg matches the capture-sink leg" do
    capture = capture_boot()

    # the Daemon.emit leg: a REAL daemon (loop: :none + attach — the
    # engine's sink IS Kyber.Daemon.emit/1, daemon.ex:143 ->
    # DurableStore.append), fixed seeds (KYBER_SEED = @agent_seed), the SAME
    # wire-log inputs (same human seed, same ts, same ids, same content)
    config_log_path = Application.get_env(:kyber, :log_path)
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14h-det-key-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14h-det-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    System.put_env("KYBER_SEED", @agent_seed)

    stop_app()
    Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
    {:ok, _} = Application.ensure_all_started(:kyber)

    try do
      assert {:ok, _pid} = Daemon.boot(keyring_dir: key_dir, tick_ms: :manual, loop: :none)

      {:ok, engine, _resume} = Kyber.Agent.attach(keyring_dir: key_dir, llm: llm(), notify: self())

      # the SAME MessageReceived (byte-identical -> same id, same session)
      {:ok, {rec_claims, rec_sig}} =
        Kyber.Events.message_received(@human_seed, @ts, "msg:det", "chan-1", "session:s1", "deterministic prompt")

      :ok = DurableStore.append(Wire.envelope({rec_claims, rec_sig}))

      # manual ticks drive the cursor: the received fires the builder, the
      # request fires the engine's answer path (the digest rides the SAME
      # Daemon.emit sink) — a handful of ticks quiesce the chain
      for _ <- 1..6 do
        _ = Daemon.tick()
      end

      pa = poll_store(fn {_id, {claims, _sig}} -> match?(%{type: "PromptAssembled"}, Schema.resolve(claims)) end)
      digest = poll_store(fn {_id, {claims, _sig}} -> match?(%{type: "StandingDigest"}, Schema.resolve(claims)) end)

      assert pa != nil, "no PromptAssembled under Daemon.emit"
      assert digest != nil, "no StandingDigest under Daemon.emit"
      {pa_id, _} = pa
      {digest_id, _} = digest

      # IDENTICAL ids to the capture-sink leg: the mint derives over the
      # set bound at the triggering dispatch's entry (H1 — pre-emission,
      # sink-independent) with the trigger-ts discipline (never wall-clock)
      assert pa_id == capture.pa_id
      assert digest_id == capture.digest_id
      assert digest_id != capture.pa_id
      _ = engine
    after
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  # bounded sleep-free store polling (the no-sleep idiom: a timeout-only
  # receive never swallows probes)
  defp poll_store(pred, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Enum.find(DurableStore.set(), pred) do
        nil ->
          receive do
          after
            25 -> :timeout
          end

          {:cont, nil}

        found ->
          {:halt, found}
      end
    end)
  end


  test "N3: a whitespace-only flagged entity id is FOLD-INERT — never repaired, never standing" do
    store = start_store()
    {:ok, mem} = Events.memory_entity(@agent_seed, @ts, "   ", "whitespace fact", [])
    put_wire(store, Wire.envelope(mem))
    {:ok, flag} = Events.standing_flag(@agent_seed, @ts + 1, "   ")
    put_wire(store, Wire.envelope(flag))
    {:ok, epoch} = Events.memory_policy(@operator_seed, @ts + 2, ["   "])
    put_wire(store, Wire.envelope(epoch))

    set = Agent.get(store, & &1)
    assert Standing.fold(set, nil) == []
  end

  test "H5: digest-of-digest exclusion — the trajectory derivation never observes its own output (StandingDigest is not a covered kind)" do
    store = start_store()
    {:ok, signed} = Events.standing_digest(@agent_seed, @ts, "session:s1", "asked: self", [id64("11")])
    put_wire(store, Wire.envelope(signed))

    set = Agent.get(store, & &1)
    %{content: content, covers: covers} = Digest.derive(set, "session:s1")

    assert content == ""
    assert covers == []
  end
  # ------------------------------------------------------------------ utils

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
end
