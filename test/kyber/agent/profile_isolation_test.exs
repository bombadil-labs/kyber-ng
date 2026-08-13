defmodule Kyber.Agent.ProfileIsolationTest do
  @moduledoc """
  T14g AC2 — profiles boot on the SAME instance as SEQUENTIAL boots over
  one store (H3: two engines over one store DOUBLE-ANSWER — the T14c
  exactly-one invariant breaks; `answered?` is not profile-aware). The
  default profile is the ABSENCE of selection; a channel profile is a
  declared ProfileSet whose memory/skill visibility is epoch-bounded (the
  `:none` gather arm FLIPS to omit-all — N1), whose capability subset is
  enforced at registry construction (G6/L1 — the SINGLE `tools` var
  feeding both the engine specs and the executor registry, `Map.take`
  intersect, the boot gate preserved), and whose tool-side policy layers
  source their epochs from the profile's families (M2). Zero new reason
  strings: every refusal spelling is the existing vocabulary.

  The witness: ONE daemon + store; boot A attaches profile-less with the
  operator seed; boot B attaches with `profile: "channel:discord"` — never
  two engines over the store (sequential). The channel boot's prompt shows
  the identity block + profile segment with NO memory notes; its tool list
  is narrowed to the profile's allow_tool; memory.read refuses under the
  profile's epochs with the EXISTING reason string.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Harness, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Events, LlmHandler, ToolExecutor}

  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)
  @human_seed String.duplicate("cd", 32)
  @ts 1_700_000_000_000.0

  defmodule StubHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, body, state) do
      send(state.reply_to, {:llm_request, JSON.decode!(body)})
      content = state.answer
      body = JSON.encode!(%{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}}]})
      {:ok, %{status: 200, body: body}}
    end
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp boot_app(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  defp append!(wire) do
    assert :ok = DurableStore.append(wire)
  end

  defp llm(answer) do
    {:ok, handler} =
      LlmHandler.new(
        seed: @agent_seed,
        api_key: "test-key-never-real",
        http: {StubHttp, %{reply_to: self(), answer: answer}},
        model: "stub-model"
      )

    handler
  end

  defp engine_tool_names(engine) do
    engine
    |> :sys.get_state()
    |> Map.fetch!(:tools)
    |> Enum.map(& &1["function"]["name"])
    |> Enum.sort()
  end

  # the memory entities' DELTA ids — the retriever seam answers ids, never
  # content (the engine rehydrates by pointer-walk)
  defp memory_ids do
    DurableStore.set()
    |> Enum.filter(fn {_id, {claims, _sig}} ->
      case Schema.resolve(claims) do
        %{type: "MemoryEntity", entity: {:entity, e, _}} -> e in ["topic:public", "topic:secret"]
        _ -> false
      end
    end)
    |> Enum.map(fn {id, _element} -> id end)
  end

  defp ingest!(keyring_dir, msg_id, content, ts) do
    source = %{
      "message_id" => msg_id,
      "channel_id" => "channel:cli:t14g",
      "session_id" => "session:cli:t14g",
      "content" => content,
      "ts" => ts
    }

    assert {:ok, _id} = Harness.ingest(source, keyring_dir)
  end

  defp tick_until_answer do
    # tick 1 dispatches the prompt (the builder fires the request); tick 2
    # dispatches the request (the engine answers asynchronously)
    assert {:ok, %{fired: _}} = Daemon.tick()
    assert {:ok, _status} = Daemon.tick()
    assert_receive {:engine, {:answered, _request_id}}, 2_000
    assert_receive {:llm_request, body}, 2_000
    body
  end

  # the seed store: identity primitives + the channel profile declaration +
  # a broad memory epoch + two memory entities (one allowed, one not) + a
  # skill with its epoch — the AC2 isolation fixtures
  defp seed_identity_store do
    {:ok, soul} = Events.identity_set(@operator_seed, @ts, "identity:soul", "soul", "I am Veles.")
    {:ok, user} = Events.identity_set(@operator_seed, @ts + 1, "identity:user", "user", "Terse operator.")
    {:ok, op} = Events.identity_set(@operator_seed, @ts + 2, "identity:operator", "operator", "No escalation.")

    {:ok, profile} =
      Events.profile_set(
        @operator_seed,
        @ts + 3,
        "channel:discord",
        "answer in character; no politics",
        ["identity:soul", "identity:user", "identity:operator"],
        ["memory.read"],
        []
      )

    # the boot memory epoch: topic:public allowed, topic:secret NOT
    {:ok, mem_policy} = Events.memory_policy(@operator_seed, @ts + 4, ["topic:public"])
    {:ok, pub} = Events.memory_entity(@agent_seed, @ts + 5, "topic:public", "the cap is a lens", [])
    {:ok, secret} = Events.memory_entity(@agent_seed, @ts + 6, "topic:secret", "classified channel data", [])

    {:ok, skill} = Events.skill_set(@agent_seed, @ts + 7, "greet", "Greet a member", "say hello warmly")
    {:ok, skill_pol} = Events.skill_policy(@agent_seed, @ts + 8, ["greet"])

    for w <- [
          Wire.envelope(soul),
          Wire.envelope(user),
          Wire.envelope(op),
          Wire.envelope(profile),
          Wire.envelope(mem_policy),
          Wire.envelope(pub),
          Wire.envelope(secret),
          Wire.envelope(skill),
          Wire.envelope(skill_pol)
        ],
        do: append!(w)
  end

  # the explicit registry (4 tools) — the capability intersect needs a
  # registry wider than the profile's allow_tool
  defp tool_registry do
    store_fn = fn -> DurableStore.set() end
    ToolExecutor.memory_tools(store_fn) |> Map.merge(ToolExecutor.skill_tools(store_fn))
  end

  setup do
    config_log_path = Application.get_env(:kyber, :log_path)
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14g-profile-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14g-profile-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    System.put_env("KYBER_SEED", @agent_seed)
    :ok = Keys.import_human_seed(@human_seed, key_dir)

    boot_app(Path.join(log_dir, "store.jsonl"))
    assert {:ok, _pid} = Daemon.boot(keyring_dir: key_dir, tick_ms: :manual, loop: :none)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir}
  end

  test "AC2: an unknown/undeclared profile refuses LOUDLY at attach — whitespace-only names unresolvable (M7), no silent fallback", ctx do
    seed_identity_store()

    assert {:error, {:unknown_profile, "nope"}} =
             Kyber.Agent.attach(
               keyring_dir: ctx.keyring_dir,
               llm: llm("x"),
               tools: tool_registry(),
               operator_seed: @operator_seed,
               profile: "nope"
             )

    # M7: a whitespace-only name is door-admissible but UNRESOLVABLE at the
    # lookup — the same loud refusal, never a repair, never a silent boot
    assert {:error, {:unknown_profile, " "}} =
             Kyber.Agent.attach(
               keyring_dir: ctx.keyring_dir,
               llm: llm("x"),
               tools: tool_registry(),
               operator_seed: @operator_seed,
               profile: " "
             )

    # a profile with NO operator seed: nothing to attest with — unresolvable
    assert {:error, {:unknown_profile, "channel:discord"}} =
             Kyber.Agent.attach(
               keyring_dir: ctx.keyring_dir,
               llm: llm("x"),
               tools: tool_registry(),
               profile: "channel:discord"
             )
  end

  test "AC2: SEQUENTIAL boots over one store — the default (profile-less) boot and the channel profile boot; the channel boot is epoch-bounded on every surface", ctx do
    seed_identity_store()

    # ---- boot A: the DEFAULT profile = the ABSENCE of selection
    {:ok, engine_a, _resume} =
      Kyber.Agent.attach(
        keyring_dir: ctx.keyring_dir,
        llm: llm("a"),
        tools: tool_registry(),
        operator_seed: @operator_seed,
        memory: {Kyber.Agent.MemoryPort.Stub, %{memories: memory_ids()}},
        notify: self()
      )

    # the profile-less boot advertises the FULL registry (no narrowing)
    assert engine_tool_names(engine_a) == ["memory_read", "skill_read", "skill_retract", "skill_set"]

    ingest!(ctx.keyring_dir, "message:t14g:a1", "please greet the new member", @ts + 100)
    body_a = tick_until_answer()

    # the identity block rides FIRST (AC1) — all three primitives, profile-less
    messages_a = body_a["messages"]
    contents_a = Enum.map(messages_a, & &1["content"])
    assert Enum.at(contents_a, 1) == "Soul: I am Veles."
    assert Enum.at(contents_a, 2) == "User: Terse operator."
    assert Enum.at(contents_a, 3) == "Operator: No escalation."

    # the profile-less gather runs the BOOT memory epoch: topic:public rides,
    # topic:secret is omitted (not allowlisted)
    assert Enum.any?(contents_a, &(&1 == "Memory: the cap is a lens"))
    refute Enum.any?(contents_a, &String.contains?(&1, "classified channel data"))

    # the skill lens rides the boot skill epoch on first assembly
    assert Enum.any?(contents_a, &String.starts_with?(&1, "Skill: greet"))

    # ---- sequential: boot A is STOPPED before boot B (never two engines)
    GenServer.stop(engine_a)

    # ---- boot B: the channel profile
    {:ok, engine_b, _resume} =
      Kyber.Agent.attach(
        keyring_dir: ctx.keyring_dir,
        llm: llm("b"),
        tools: tool_registry(),
        operator_seed: @operator_seed,
        profile: "channel:discord",
        memory: {Kyber.Agent.MemoryPort.Stub, %{memories: memory_ids()}},
        notify: self()
      )

    # G6/L1: the capability subset NARROWS the SINGLE registry — the model
    # sees only the profile's allow_tool ∩ boot registry
    assert engine_tool_names(engine_b) == ["memory_read"]

    ingest!(ctx.keyring_dir, "message:t14g:b1", "hello channel", @ts + 200)
    body_b = tick_until_answer()

    messages_b = body_b["messages"]
    contents_b = Enum.map(messages_b, & &1["content"])

    # the identity block still rides (the profile rides all three) + the
    # "Profile: <name>\n" rules segment AFTER the primitives (G3/H5)
    assert Enum.at(contents_b, 1) == "Soul: I am Veles."
    assert Enum.at(contents_b, 4) == "Profile: channel:discord\nanswer in character; no politics"

    # N1/G8: the :none gather arm FLIPS under a profile — the channel
    # profile names NO family, so its epochs are the derived empty-until-
    # seeded defaults: NOTHING leaks through the gather (not even topic:public)
    refute Enum.any?(contents_b, &String.starts_with?(&1, "Memory: "))

    # M2/G8: the skill lens sources the profile's families — derived default
    # "skill:profile/channel:discord" is unseeded: no skill notes ride
    refute Enum.any?(contents_b, &String.starts_with?(&1, "Skill: "))

    # the replay seam: each boot minted its OWN profile-keyed claim — the
    # channel boot's PromptAssembled rides the "channel:discord" key; the
    # profile-less boot's claim is unkeyed (N2/H4)
    pa_keyed =
      DurableStore.set()
      |> Enum.filter(fn {_id, {claims, _sig}} ->
        match?(%{type: "PromptAssembled", profile: "channel:discord"}, Schema.resolve(claims))
      end)

    pa_unkeyed =
      DurableStore.set()
      |> Enum.filter(fn {_id, {claims, _sig}} ->
        case Schema.resolve(claims) do
          %{type: "PromptAssembled", profile: nil} -> true
          _ -> false
        end
      end)

    assert length(pa_keyed) == 1
    assert length(pa_unkeyed) == 1

    GenServer.stop(engine_b)
  end

  test "AC2: the tool surface is profile-aware — memory.read refuses under the profile's epochs with the EXISTING reason string (M2)", ctx do
    seed_identity_store()

    {:ok, engine_b, _resume} =
      Kyber.Agent.attach(
        keyring_dir: ctx.keyring_dir,
        llm: llm("b"),
        tools: tool_registry(),
        operator_seed: @operator_seed,
        profile: "channel:discord",
        gate: Kyber.Agent.Action.Gate.new(allow: ["memory.read"]),
        notify: self()
      )

    # a crafted memory.read call (the gate allows it; the POLICY layer then
    # decides) — under the profile the epoch source is the derived
    # "memory:profile/channel:discord" family: unseeded => governs nothing
    args = JSON.encode!(%{"entity" => "topic:public"})

    {:ok, {claims, sig}} =
      Events.tool_call(@agent_seed, @ts + 300, "memory.read", args, "req-tool-1")

    wire = Wire.envelope({claims, sig})
    {:ok, %{id: call_id}} = Store.verify(wire)
    assert :ok = DurableStore.append(wire)
    assert {:ok, %{fired: _}} = Daemon.tick()
    assert {:ok, _} = Daemon.tick()

    set = DurableStore.set()

    # the refusal: GateDecision "refuse" with the EXISTING reason string —
    # zero new reason strings (the union epoch has no single id, so the
    # policy_epoch pointer rides nil — omitted; the refusal spelling is the
    # pinned memory_policy vocabulary)
    decision =
      Enum.find_value(set, fn {_id, {c, _sig}} ->
        case Schema.resolve(c) do
          %{type: "GateDecision", decides: {:delta, ^call_id, _}} = d -> d
          _ -> nil
        end
      end)

    refute is_nil(decision), "no GateDecision for the memory.read call"
    assert decision.verdict == "refuse"
    assert decision.policy == "memory_policy"
    assert decision.reason == Kyber.Agent.Policy.reason_memory_entity()

    # NO ToolResult for the refused call (reject, never repair)
    refute Enum.any?(set, fn {_id, {c, _sig}} ->
             match?(%{type: "ToolResult"}, Schema.resolve(c))
           end)

    GenServer.stop(engine_b)
  end
end
