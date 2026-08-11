defmodule Kyber.Agent.DigestReplayTest do
  @moduledoc """
  T14h N2/H3/AC3 — the replay-key matrix: the replay seam's key is the
  (profile, sorted {family, epoch-id} roster + ProfileSet head id) material
  (match-or-rederive; the digest id is NEVER the key). The rotation door:
  a same-profile memory-epoch rotation (wide -> narrow) changes the roster
  => the stored claim MISSES => the engine re-derives (stale wide-epoch
  always-on bytes are never re-served through stored-claim-wins). The key
  rides ONLY under a profile — profile-less mints stay byte-identical (the
  L4 recorded debt). A legacy profile-keyed claim WITHOUT the material is a
  MISS under a profiled boot (the roster cannot be verified).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{ContextBuilder, Engine, Events, LlmHandler, MemoryPort, Prompt}
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
    {:ok, signed} = Kyber.Events.message_received(@human_seed, ts, msg_id, "chan-1", "session:s1", content)
    put_wire(store, Wire.envelope(signed))
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

  # the engine's own key-material derivation (Prompt.replay_key + the
  # builder) — the fixture-claim builder for stored-claim scenarios
  defp key_material_id(set, boot, seed, ts) do
    %{profile: profile, roster: roster, head: head} = Prompt.replay_key(set, boot)
    {:ok, {km_claims, _sig}} = Events.epoch_key_material(seed, ts, profile, roster, head)
    Delta.id_hex(km_claims)
  end

  defp profile_set(store, name, families) do
    {:ok, signed} =
      Events.profile_set(@operator_seed, @ts + 1, name, "rules", [], [], families)

    put_wire(store, Wire.envelope(signed))
  end

  # a memory epoch for the named family with the given allowlist
  defp memory_epoch(store, ts, family, allow, supersedes \\ nil) do
    {:ok, {claims, sig}} = Kyber.Agent.Events.memory_policy(@operator_seed, ts, allow, supersedes)
    put_wire(store, Wire.envelope({claims, sig}))
    Delta.id_hex(claims)
  end

  # ------------------------------------------------------------------ tests

  test "H3: the key material is the SORTED {family, epoch-id} roster + the ProfileSet head id — never a bare epoch id" do
    store = start_store()
    profile_set(store, "channel:discord", ["memory", "skill"])
    epoch_id = memory_epoch(store, @ts + 2, "memory", ["e1"])

    set = Agent.get(store, & &1)
    material = Prompt.replay_key(set, {"channel:discord", keys_author()})

    assert %{profile: "channel:discord"} = material
    assert is_binary(material.roster)
    assert material.roster =~ "memory"
    assert material.roster =~ epoch_id
    assert is_binary(material.head)
    # sorted pairs ride as canonical JSON (arrays, never tuples)
    assert [["memory", ^epoch_id], ["skill", nil]] = JSON.decode!(material.roster)
  end

  defp keys_author, do: Kyber.Keys.author_for_seed(@operator_seed)

  test "N2: the replay key rides ONLY under a profile — profile-less mints stay BYTE-IDENTICAL (no profile pointer, no replayKey pointer)" do
    store = start_store()
    engine = start_engine(store, boot: {nil, nil})

    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request_inference(store, engine, prompt)

    {_pa, pa_delta} = sink_typed("PromptAssembled")
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    sink_typed("StandingDigest")

    # profile-less: NO new pointers — byte-identical to pre-T14h
    refute Enum.any?(pa_delta.claims.pointers, &(&1.role in ["profile", "replayKey"]))

    # no EpochKeyMaterial was emitted either
    set = Agent.get(store, & &1)
    refute Enum.any?(set, fn {_id, {claims, _sig}} ->
      match?(%{type: "EpochKeyMaterial"}, Schema.resolve(claims))
    end)
  end

  test "N2: the (profile, roster, head) key serves a re-boot under the SAME profile with the SAME roster — stored-claim-wins, no re-mint" do
    store = start_store()
    profile_set(store, "channel:discord", ["memory"])
    memory_epoch(store, @ts + 2, "memory", ["e1"])

    engine = start_engine(store, boot: {"channel:discord", keys_author()})
    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine, prompt)

    {_pa, pa_delta} = sink_typed("PromptAssembled")
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    sink_typed("StandingDigest")

    # the minted PA carries the material key (replayKey -> the key-material id)
    assert Enum.any?(pa_delta.claims.pointers, &(&1.role == "profile"))
    assert Enum.any?(pa_delta.claims.pointers, &(&1.role == "replayKey"))

    # a re-boot under the SAME profile: the crash-window re-fire is a
    # counted skip — the key matches, the stored claim wins
    engine2 = start_engine(store, boot: {"channel:discord", keys_author()})
    assert Engine.handler(engine2).([request]) == []
    assert %{skipped: 1} = Engine.status(engine2)
    refute_receive {:sink, _wire}, 100
  end

  test "N2: the ROTATION door — a wide -> narrow memory-epoch rotation changes the roster, the key MISSES, the engine re-derives" do
    store = start_store()
    profile_set(store, "channel:discord", ["memory"])

    # wide epoch: e1 + e2 allowed
    wide_id = memory_epoch(store, @ts + 2, "memory", ["e1", "e2"])

    # the crash window: a stored PA keyed under the WIDE material, the
    # request UNANSWERED (no ResponseDelta yet)
    stored = Prompt.canonical([%{"role" => "system", "content" => "wide-era bytes"}])
    prompt = ingest_received(store, @ts, "msg-1", "hello")

    set_wide = Agent.get(store, & &1)
    wide_km = key_material_id(set_wide, {"channel:discord", keys_author()}, @agent_seed, @ts)

    {:ok, {pa_claims, pa_sig}} =
      Events.prompt_assembled(@agent_seed, @ts, "req-rot", "session:s1", stored, "channel:discord", wide_km)

    put_wire(store, Wire.envelope({pa_claims, pa_sig}))

    # NOW rotate: a NARROW memory epoch supersedes the wide one — the
    # roster changes while the profile name stays the same
    memory_epoch(store, @ts + 3, "memory", ["e1"], wide_id)

    # the crash-window re-fire under the same profile: the stored claim's
    # key material (wide roster) != the current material (narrow roster) =>
    # MISS => the engine re-derives and mints a FRESH keyed PA
    request = raw_request("req-rot", prompt)
    engine = start_engine(store, boot: {"channel:discord", keys_author()})
    assert Engine.handler(engine).([request]) == []

    {_pa2, pa2_delta} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    sink_typed("StandingDigest")

    # the model saw FRESH bytes (the stale wide-era claim never cross-served)
    refute body["messages"] == Prompt.decode(stored) |> elem(1)

    # the fresh mint is keyed under the CURRENT (narrow) material
    assert Enum.any?(pa2_delta.claims.pointers, &(&1.role == "profile"))
    narrow_km = key_material_id(Agent.get(store, & &1), {"channel:discord", keys_author()}, @agent_seed, @ts)
    assert find_target(pa2_delta.claims, "replayKey") == {:delta, narrow_km, "keyed"}
  end

  test "N2: a legacy profile-keyed claim WITHOUT the material is a MISS under a profiled boot — the roster cannot be verified" do
    store = start_store()
    profile_set(store, "channel:discord", ["memory"])
    memory_epoch(store, @ts + 2, "memory", ["e1"])

    stored = Prompt.canonical([%{"role" => "system", "content" => "stored bytes"}])

    # the T14g-era claim: profile-keyed, NO replayKey material
    {:ok, {pa_claims, pa_sig}} =
      Events.prompt_assembled(@agent_seed, @ts, "req-legacy", "session:s1", stored, "channel:discord")

    put_wire(store, Wire.envelope({pa_claims, pa_sig}))
    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine = start_engine(store, boot: {"channel:discord", keys_author()}), prompt)

    {_pa2, pa2_delta} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000

    # the model saw FRESH bytes, not the legacy claim's — and the fresh
    # mint carries the material
    refute body["messages"] == Prompt.decode(stored) |> elem(1)
    assert Enum.any?(pa2_delta.claims.pointers, &(&1.role == "replayKey"))
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    sink_typed("StandingDigest")
    _ = request
  end

  test "H3: the digest id is NEVER the key — a stored claim keyed to the StandingDigest id misses and re-derives" do
    store = start_store()
    profile_set(store, "channel:discord", ["memory"])
    memory_epoch(store, @ts + 2, "memory", ["e1"])

    stored = Prompt.canonical([%{"role" => "system", "content" => "stored bytes"}])

    # mint a digest and (wrongly) key the stored PA to the DIGEST id
    {:ok, {digest_claims, _}} = Events.standing_digest(@agent_seed, @ts, "session:s1", "asked: hi", [])
    digest_id = Delta.id_hex(digest_claims)

    {:ok, {pa_claims, pa_sig}} =
      Events.prompt_assembled(@agent_seed, @ts, "req-d", "session:s1", stored, "channel:discord", digest_id)

    put_wire(store, Wire.envelope({pa_claims, pa_sig}))
    prompt = ingest_received(store, @ts, "msg-1", "hello")
    request = request_inference(store, engine = start_engine(store, boot: {"channel:discord", keys_author()}), prompt)

    {_pa2, pa2_delta} = sink_typed("PromptAssembled")
    assert_receive {:llm_request, body}, 2_000

    refute body["messages"] == Prompt.decode(stored) |> elem(1)
    # the fresh mint's replayKey points at the KEY-MATERIAL id, never the digest
    {:string, profile} = find_target(pa2_delta.claims, "profile")
    assert profile == "channel:discord"
    km_id = key_material_id(Agent.get(store, & &1), {"channel:discord", keys_author()}, @agent_seed, @ts)
    assert find_target(pa2_delta.claims, "replayKey") == {:delta, km_id, "keyed"}
    refute find_target(pa2_delta.claims, "replayKey") == {:delta, digest_id, "keyed"}
    sink_typed("ResponseDelta")
    sink_typed("MessageSent")
    sink_typed("StandingDigest")
    _ = request
  end

  # the raw-admission door: an InferenceRequested with a PINNED id (the
  # fixture pattern — the builder mints fresh ids)
  defp raw_request(request_id, prompt_delta) do
    claims = %{
      timestamp: @ts,
      author: Kyber.Keys.author_for_seed(@agent_seed),
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

  defp find_target(claims, role) do
    Enum.find_value(claims.pointers, fn
      %{role: ^role, target: target} -> target
      _other -> nil
    end)
  end
end
