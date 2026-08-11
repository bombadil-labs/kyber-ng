defmodule Kyber.Agent.IdentityGenesisTest do
  @moduledoc """
  T14g G2/H4 — genesis evolution is a DELIVERABLE: the IdentitySet +
  ProfileSet kinds ride the genesis `@defs`, the committed `genesis.jsonl`
  is REGENERATED (byte-for-byte gated by schema_test.exs's round-trip),
  the `Events.identity_set` / `Events.profile_set` builders are the house
  emission seam, and the PromptAssembled schema carries the optional
  `profile` string key (N2). The fold only sees TYPED deltas — a genesis
  drift would blind it silently — so this file pins the kinds, the field
  shapes, the door round-trip, and the PROFILE-KEYED REPLAY MATRIX (H4):
  keyed-vs-unkeyed is a MISS both ways (a legacy unkeyed claim never
  serves a profiled boot and vice versa), and exactly-one per (request,
  profile).
  """
  use ExUnit.Case, async: false

  alias Kyber.{Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Engine, Events, LlmHandler, Prompt}
  alias Kyber.Agent.ContextBuilder
  alias Kyber.Agent.MemoryPort
  alias Kyber.Schema.Genesis
  alias Rhizomatic.Delta

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
      Kyber.Events.message_received(String.duplicate("a1", 32), ts, msg_id, "chan-1", "session:s1", content)

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

  # ------------------------------------------------------ kinds + field shapes

  test "G2: IdentitySet and ProfileSet ride the compiled genesis set with the pinned field shapes" do
    schemas = Genesis.compiled().schemas

    # IdentitySet: the entity pointer rides as role `entity` (the MemoryEntity
    # precedent, pinned deliberately); kind and body are required strings;
    # source is the optional provenance delta pointer (M5c)
    assert %{fields: id_fields} = schemas["IdentitySet"]
    assert id_fields["entity"].kind == :entity
    assert id_fields["entity"].arity == :one
    assert id_fields["kind"].kind == :string
    assert id_fields["kind"].arity == :one
    assert id_fields["body"].kind == :string
    assert id_fields["body"].arity == :one
    assert id_fields["source"].kind == :delta
    assert id_fields["source"].arity == :maybe

    # ProfileSet: name rides as the `profile` entity aggregate key, rules a
    # required string; rides are identity:<id> ENTITY refs (many), allow_tool
    # and families are strings (many) — M5b
    assert %{fields: pf_fields} = schemas["ProfileSet"]
    assert pf_fields["profile"].kind == :entity
    assert pf_fields["profile"].arity == :one
    assert pf_fields["rules"].kind == :string
    assert pf_fields["rules"].arity == :one
    assert pf_fields["rides"].kind == :entity
    assert pf_fields["rides"].arity == :many
    assert pf_fields["allow_tool"].kind == :string
    assert pf_fields["allow_tool"].arity == :many
    assert pf_fields["families"].kind == :string
    assert pf_fields["families"].arity == :many

    # N2/H4: PromptAssembled carries the OPTIONAL profile string key — the
    # genesis cost of the replay key (profile-less mints stay byte-identical)
    assert %{fields: pa_fields} = schemas["PromptAssembled"]
    assert pa_fields["profile"].kind == :string
    assert pa_fields["profile"].arity == :maybe
  end

  # --------------------------------------------------------------- the door

  test "G2: a minted IdentitySet admits through the door and resolves typed — the fold's input is typed, never raw" do
    {:ok, {claims, sig}} =
      Events.identity_set(@operator_seed, @ts, "identity:soul", "soul", "I am Veles.", "attest:1")

    wire = Wire.envelope({claims, sig})

    assert {:ok, %{id: _id, claims: ^claims}} = Store.verify(wire)
    assert %{type: "IdentitySet"} = Schema.resolve(claims)
    assert {:ok, %Kyber.Schema.IdentitySet{}} = Schema.validate(claims)

    assert %Kyber.Schema.IdentitySet{
             entity: {:entity, "identity:soul", "identity"},
             kind: "soul",
             body: "I am Veles.",
             source: {:delta, "attest:1", "attested"}
           } = Schema.resolve(claims)
  end

  test "G2: a minted ProfileSet admits through the door and resolves typed — the full payload rides" do
    {:ok, {claims, sig}} =
      Events.profile_set(
        @operator_seed,
        @ts,
        "channel:discord",
        "no politics",
        ["identity:soul", "identity:user"],
        ["tool:echo", "fs.read"],
        ["memory"]
      )

    wire = Wire.envelope({claims, sig})

    assert {:ok, %{id: _id, claims: ^claims}} = Store.verify(wire)
    assert %Kyber.Schema.ProfileSet{} = Schema.resolve(claims)

    assert %Kyber.Schema.ProfileSet{
             profile: {:entity, "channel:discord", "profiles"},
             rules: "no politics",
             rides: [{:entity, "identity:soul", "rides"}, {:entity, "identity:user", "rides"}],
             allow_tool: ["tool:echo", "fs.read"],
             families: ["memory"]
           } = Schema.resolve(claims)
  end

  test "G2: the builders are the drift-proof emission seam — emitter roles EXACTLY the schema field set" do
    for {emitter, type, args} <- [
          {&Events.identity_set/6, "IdentitySet",
           {@operator_seed, @ts, "identity:soul", "soul", "body", id64("99")}},
          {&Events.profile_set/7, "ProfileSet",
           {@operator_seed, @ts, "channel:discord", "rules", ["identity:soul"], ["tool:echo"], ["memory"]}},
          # N2: the /6 builder with the profile key — profile-less /5 stays
          # byte-identical (no profile pointer)
          {&Events.prompt_assembled/6, "PromptAssembled",
           {@agent_seed, @ts, "req-1", "session:s1", "{}", "channel:discord"}}
        ] do
      {:ok, {claims, _sig}} = apply(emitter, Tuple.to_list(args))

      roles =
        claims.pointers |> Enum.map(& &1.role) |> Enum.reject(&(&1 == "type")) |> Enum.sort()

      schema_fields = Genesis.compiled().schemas[type].fields |> Map.keys() |> Enum.sort()
      assert roles == schema_fields, "schema #{type} drifted from its emitter"

      assert {:ok, typed} = Schema.validate(claims)
      assert typed.type == type
    end

    # profile-less /5: NO profile pointer — byte-identical to pre-T14g
    {:ok, {claims, _sig}} = Events.prompt_assembled(@agent_seed, @ts, "req-1", "session:s1", "{}")
    refute Enum.any?(claims.pointers, &(&1.role == "profile"))
  end

  test "G2: the genesis round-trip — committed wire data reproduces the build byte-for-byte (the regenerated genesis.jsonl)" do
    committed =
      "lib/kyber/schema/genesis/wire/genesis.jsonl"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        {:ok, wire} = Wire.decode(line)
        wire
      end)

    built = Genesis.deltas()

    assert Enum.map(built, & &1["id"]) |> Enum.sort() ==
             Enum.map(committed, & &1["id"]) |> Enum.sort()

    assert Enum.sort_by(built, & &1["id"]) == Enum.sort_by(committed, & &1["id"])
  end

  # ------------------------------------------- the replay-key matrix (N2/H4)

  test "H4: a KEYED PromptAssembled serves a re-boot under the SAME profile — the crash window reuses the stored claim, no re-mint" do
    store = start_store()
    engine = start_engine(store, boot: {"channel:discord", "author"})

    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine, prompt)

    {_pa, _} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, _body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # a re-boot under the SAME profile reuses the stored claim: the crash-
    # window re-fire (the SAME InferenceRequested re-routed) is a counted
    # skip — never a re-mint
    engine2 = start_engine(store, boot: {"channel:discord", "author"})
    assert Engine.handler(engine2).([request]) == []
    assert %{skipped: 1} = Engine.status(engine2)
    refute_receive {:sink, _wire}, 100
  end

  test "H4: a KEYED claim never matches a profile-less boot — the A->B leak through OLD stores is closed (re-derive, never cross-serve)" do
    store = start_store()
    engine = start_engine(store, boot: {"channel:discord", "author"})

    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine, prompt)

    {_pa, _} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, _body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # NOW re-boot profile-less (a fresh request — the old one is answered):
    # the keyed claim can never serve this boot; a NEW unkeyed mint rides
    prompt2 = ingest_received(store, @ts + 1, "msg-2", "hello again")
    engine2 = start_engine(store, boot: {nil, "author"})
    _ = request_inference(store, engine2, prompt2)

    {_pa2_typed, pa2_delta} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, _body2}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # the fresh mint is UNKEYED (profile-less boots mint byte-identical
    # unkeyed claims — N2)
    refute Enum.any?(pa2_delta.claims.pointers, &(&1.role == "profile"))
  end

  test "H4: an UNKEYED pre-T14g claim never serves a profiled boot — keyed-vs-unkeyed is a MISS, never a cross-serve" do
    store = start_store()

    # the LEGACY store artifact: an unkeyed PromptAssembled for the request
    # (pre-T14g builder shape), with NO ResponseDelta yet — the crash window
    {:ok, {legacy_claims, legacy_sig}} =
      Events.prompt_assembled(@agent_seed, @ts, "req-legacy", "session:s1", "legacy bytes")

    put_wire(store, Wire.envelope({legacy_claims, legacy_sig}))

    # a profiled boot over that store: the unkeyed claim must NOT match —
    # the engine re-derives and mints a NEW KEYED PromptAssembled
    engine = start_engine(store, boot: {"channel:discord", "author"})

    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine, prompt)

    {_pa_typed, pa_delta} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000

    # the model saw the FRESH bytes, not the legacy claim's bytes
    assert body["messages"] != Prompt.decode("legacy bytes") |> elem(1)

    # the fresh mint is KEYED under the boot profile
    assert {:string, "channel:discord"} in
             Enum.map(pa_delta.claims.pointers, & &1.target)

    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    _ = request
  end

  test "H4 (the REAL isolation leg): the crash window — a stored KEYED claim under the SAME profile is REPLAYED (no re-mint); under a DIFFERENT profile it MISSES and re-derives" do
    # ---- scenario 1: the SAME profile — replay hit
    store1 = start_store()
    stored = Prompt.canonical([%{"role" => "system", "content" => "stored system"}, %{"role" => "user", "content" => "hi"}])

    {:ok, {pa1_claims, pa1_sig}} =
      Events.prompt_assembled(@agent_seed, @ts, "req-cw1", "session:s1", stored, "channel:discord")

    put_wire(store1, Wire.envelope({pa1_claims, pa1_sig}))
    prompt1 = ingest_received(store1, @ts, "msg-1", "hi")
    request1 = raw_request("req-cw1", prompt1)

    engine1 = start_engine(store1, boot: {"channel:discord", "author"})
    assert Engine.handler(engine1).([request1]) == []
    assert_receive {:llm_request, body1}, 2_000

    # the model saw the STORED canonical bytes — replayed, never re-minted
    # (no fresh PromptAssembled: the replay path emits nothing)
    assert body1["messages"] == Prompt.decode(stored) |> elem(1)
    refute_receive {:sink, %{"claims" => %{"pointers" => [%{"role" => "sessionId"} | _]}}}, 100
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")

    # ---- scenario 2: a DIFFERENT profile — key MISS, re-derive + fresh
    # mint keyed under the NEW profile (the A->B leak is closed)
    store2 = start_store()

    {:ok, {pa2_claims, pa2_sig}} =
      Events.prompt_assembled(@agent_seed, @ts, "req-cw2", "session:s1", stored, "channel:discord")

    put_wire(store2, Wire.envelope({pa2_claims, pa2_sig}))
    prompt2 = ingest_received(store2, @ts, "msg-1", "hi")
    request2 = raw_request("req-cw2", prompt2)

    engine2 = start_engine(store2, boot: {"other:profile", "author"})
    assert Engine.handler(engine2).([request2]) == []
    {_typed2, pa2_delta} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, body2}, 2_000

    # the model saw FRESH bytes (the stored claim did NOT cross-serve) and
    # the fresh mint is keyed under the new profile
    assert body2["messages"] != Prompt.decode(stored) |> elem(1)
    assert Enum.any?(pa2_delta.claims.pointers, &(&1 == %{role: "profile", target: {:string, "other:profile"}}))
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
  end

  # the raw-admission door: an InferenceRequested with a PINNED id, so the
  # stored PromptAssembled's requestRef matches (the builder mints fresh ids)
  defp raw_request(request_id, prompt_delta) do
    claims = %{
      timestamp: @ts,
      author: Keys.author_for_seed(@agent_seed),
      pointers: [
        %{role: "promptRef", target: {:delta, prompt_delta.id, "requested"}},
        %{role: "model", target: {:string, "stub-model"}},
        %{role: "sessionId", target: {:entity, "session:s1", "inferences"}},
        %{role: "conversationRef", target: {:delta, "conv-ref", "context_of"}},
        %{role: "type", target: {:entity, "InferenceRequested", "instances"}}
      ]
    }

    %{id: request_id, claims: claims}
  end
end
