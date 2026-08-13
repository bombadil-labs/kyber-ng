defmodule Kyber.Agent.T17ConfigFoldTest do
  @moduledoc """
  T17 — the AgentSet fold core (AC5, AC11, AC14, AC15, AC16 fold-side).

  An agent's operational identity is an entity folded over its own AgentSet
  delta stream: deltas SET properties, facts merge, values supersede
  (last-set-wins per field), retraction is negation (per-field step-back).
  The H2c author filter applies with a PROSPECTIVE self_config grant;
  base_url folds only when operator-attested, ALWAYS. Dedup is
  semantics-aware: re-asserting the current fold value is a no-op,
  re-asserting a PREVIOUS value produces a new delta that re-wins.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Keys, Schema}
  alias Kyber.Agent.{Config, Events}
  alias Rhizomatic.Delta

  @operator_seed String.duplicate("7f", 32)
  @agent_seed String.duplicate("b7", 32)
  @intruder_seed String.duplicate("c9", 32)
  @ts 1_700_000_000_000.0

  # mirror the genesis default layer AC14 pins
  @genesis_fields %{
    base_url: "https://api.deepseek.com/v1",
    model: "deepseek-v4-flash",
    api_key_env: "DEEPSEEK_API_KEY",
    oracle_seed: "absent",
    loop: "reactor",
    channel_socket: "default",
    self_config: "false"
  }

  defp agent_set(name, fields, opts \\ []) do
    seed = Keyword.get(opts, :seed, @operator_seed)
    ts = Keyword.get(opts, :ts, @ts)
    {:ok, {claims, sig}} = Events.agent_set(seed, ts, name, fields)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp agent_retract(name, target_id, opts) do
    seed = Keyword.get(opts, :seed, @operator_seed)
    ts = Keyword.get(opts, :ts, @ts + 100)
    {:ok, {claims, sig}} = Events.agent_retract(seed, ts, name, target_id)
    {Delta.id_hex(claims), {claims, sig}}
  end

  defp set_of(pairs) do
    Map.new(pairs, fn {_id, {claims, _sig} = element} -> {Delta.id_hex(claims), element} end)
  end

  # ------------------------------------------------------------ the builders

  describe "Events.agent_set/4 + genesis registration" do
    test "builds a signed, schema-valid AgentSet delta (kind marker first, type last)" do
      {:ok, {claims, _sig}} =
        Events.agent_set(@operator_seed, @ts, "wisp", %{
          soul: "I am wisp.",
          model: "deepseek-v4-flash"
        })

      assert claims.author == Keys.author_for_seed(@operator_seed)
      assert hd(claims.pointers) == %{role: "agent", target: {:entity, "wisp", "agents"}}
      assert List.last(claims.pointers) == %{role: "type", target: {:entity, "AgentSet", "instances"}}

      resolved = Schema.resolve(claims)
      assert %{type: "AgentSet", agent: {:entity, "wisp", _}, soul: "I am wisp."} = resolved
      assert resolved.model == "deepseek-v4-flash"
    end

    test "unset field names ride as many-role strings" do
      {:ok, {claims, _sig}} = Events.agent_set(@operator_seed, @ts, "wisp", %{unset: ["model", "soul"]})
      assert %{type: "AgentSet", unset: ["model", "soul"]} = Schema.resolve(claims)
    end

    test "agent_retract builds a negation pointing at the target delta" do
      {t_id, _} = agent_set("wisp", %{model: "kimi-k3"})
      {:ok, {claims, _sig}} = Events.agent_retract(@operator_seed, @ts + 1, "wisp", t_id)

      assert %{type: "AgentRetract", agent: {:entity, "wisp", _}, negates: {:delta, ^t_id, _}} =
               Schema.resolve(claims)
    end
  end

  # ---------------------------------------------------------------- the fold

  describe "Config.resolve/2 — layering + last-set-wins (AC14)" do
    test "genesis layer then seed delta: named fields override, the rest fall through" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      seed = agent_set("wisp", %{soul: "I am wisp, the quiet sibling."}, ts: @ts + 1)
      set = set_of([genesis, seed])

      assert {:ok, view} = Config.resolve(set, "wisp")
      assert view.soul == "I am wisp, the quiet sibling."
      assert view.model == "deepseek-v4-flash"
      assert view.base_url == "https://api.deepseek.com/v1"
      assert view.api_key == {:env, "DEEPSEEK_API_KEY"}
      assert view.oracle_seed == "absent"
      assert view.loop == "reactor"
      assert view.self_config == false
      assert view.operator_author == Keys.author_for_seed(@operator_seed)
    end

    test "last-set-wins per field: a later model delta supersedes, soul untouched" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{soul: "quiet"}, ts: @ts + 1),
        agent_set("wisp", %{model: "kimi-k3"}, ts: @ts + 2)
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      assert view.model == "kimi-k3"
      assert view.soul == "quiet"
      assert view.base_url == "https://api.deepseek.com/v1"
    end

    test "api_key is a tagged union: setting enc supersedes env and vice versa" do
      enc = Base.encode64(:crypto.strong_rand_bytes(44))

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{api_key_enc: enc}, ts: @ts + 1)
      ]

      assert {:ok, %{api_key: {:enc, ^enc}}} = Config.resolve(set_of(pairs), "wisp")

      pairs = pairs ++ [agent_set("wisp", %{api_key_env: "OTHER_KEY"}, ts: @ts + 2)]
      assert {:ok, %{api_key: {:env, "OTHER_KEY"}}} = Config.resolve(set_of(pairs), "wisp")
    end

    test "unset clears a field back to absent (falls through to earlier layers only via retraction, not unset)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{soul: "quiet"}, ts: @ts + 1),
        agent_set("wisp", %{unset: ["soul"]}, ts: @ts + 2)
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      assert view.soul == nil
    end

    test ":not_found for an unknown or whitespace-only name and for the empty set" do
      assert Config.resolve(%{}, "wisp") == :not_found
      set = set_of([agent_set("wisp", @genesis_fields)])
      assert Config.resolve(set, "ghost") == :not_found
      assert Config.resolve(set, "   ") == :not_found
    end
  end

  describe "Config.resolve/2 — retraction is negation (AC11, AC15, AC16)" do
    test "retracting the override steps the field back to the previous live setter" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      {override_id, _} = override = agent_set("wisp", %{model: "kimi-k3"}, ts: @ts + 1)
      retraction = agent_retract("wisp", override_id, ts: @ts + 2)

      set = set_of([genesis, override, retraction])
      assert {:ok, view} = Config.resolve(set, "wisp")
      assert view.model == "deepseek-v4-flash"
    end

    test "retracting the retraction restores the override (recursive-existential liveness)" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      {override_id, _} = override = agent_set("wisp", %{model: "kimi-k3"}, ts: @ts + 1)
      {retraction_id, _} = retraction = agent_retract("wisp", override_id, ts: @ts + 2)
      restore = agent_retract("wisp", retraction_id, ts: @ts + 3)

      set = set_of([genesis, override, retraction, restore])
      assert {:ok, %{model: "kimi-k3"}} = Config.resolve(set, "wisp")
    end

    test "retracting the genesis layer with nothing else live yields :not_found (AC16)" do
      {genesis_id, _} = genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      retraction = agent_retract("wisp", genesis_id, ts: @ts + 1)

      assert Config.resolve(set_of([genesis, retraction]), "wisp") == :not_found
    end

    test "a non-operator retraction of an operator delta is inert (H2c on negations)" do
      {genesis_id, _} = genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      rogue = agent_retract("wisp", genesis_id, seed: @intruder_seed, ts: @ts + 1)

      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set_of([genesis, rogue]), "wisp")
    end
  end

  describe "Config.resolve/2 — H2c author filter + prospective grant (AC5)" do
    test "an agent-authored delta is fold-inert when self_config is false" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{model: "evil-model"}, seed: @agent_seed, ts: @ts + 1)
      ]

      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set_of(pairs), "wisp")
    end

    test "the flip-test: the same agent delta folds only under a prior grant head" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      grant = agent_set("wisp", %{self_config: "true"}, ts: @ts + 1)
      agent_delta = agent_set("wisp", %{model: "agent-choice"}, seed: @agent_seed, ts: @ts + 2)

      with_grant = set_of([genesis, grant, agent_delta])
      assert {:ok, %{model: "agent-choice"}} = Config.resolve(with_grant, "wisp")

      without_grant = set_of([genesis, agent_delta])
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(without_grant, "wisp")
    end

    test "the grant is PROSPECTIVE: a pre-grant agent delta stays inert forever" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      stale = agent_set("wisp", %{model: "stale-agent-model"}, seed: @agent_seed, ts: @ts + 1)
      grant = agent_set("wisp", %{self_config: "true"}, ts: @ts + 2)

      assert {:ok, %{model: "deepseek-v4-flash"}} =
               Config.resolve(set_of([genesis, stale, grant]), "wisp")
    end

    test "revocation: agent deltas after an operator self_config: false are inert again" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{self_config: "false"}, ts: @ts + 2),
        agent_set("wisp", %{model: "post-revoke"}, seed: @agent_seed, ts: @ts + 3)
      ]

      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set_of(pairs), "wisp")
    end

    test "retracting the grant delta de-activates the agent deltas it admitted" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      {grant_id, _} = grant = agent_set("wisp", %{self_config: "true"}, ts: @ts + 1)
      agent_delta = agent_set("wisp", %{model: "agent-choice"}, seed: @agent_seed, ts: @ts + 2)
      retraction = agent_retract("wisp", grant_id, ts: @ts + 3)

      set = set_of([genesis, grant, agent_delta, retraction])
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set, "wisp")
    end

    test "base_url is operator-attested ALWAYS: an agent delta never folds it (P0)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{base_url: "https://evil.proxy/v1", model: "agent-choice"},
          seed: @agent_seed,
          ts: @ts + 2
        )
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      # the model change folds (granted); the base_url change NEVER does
      assert view.model == "agent-choice"
      assert view.base_url == "https://api.deepseek.com/v1"
    end

    test "an agent retraction can negate its own folded delta but not an operator's" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      {genesis_id, _} = genesis
      grant = agent_set("wisp", %{self_config: "true"}, ts: @ts + 1)
      {own_id, _} = own = agent_set("wisp", %{model: "agent-choice"}, seed: @agent_seed, ts: @ts + 2)
      own_retract = agent_retract("wisp", own_id, seed: @agent_seed, ts: @ts + 3)

      set = set_of([genesis, grant, own, own_retract])
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set, "wisp")

      rogue = agent_retract("wisp", genesis_id, seed: @agent_seed, ts: @ts + 4)
      set = set_of([genesis, grant, own, own_retract, rogue])
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set, "wisp")
    end
  end

  # ------------------------------------------------- semantics-aware dedup

  describe "Config.changed_fields/2 — semantics-aware dedup (AC8 premortem)" do
    test "re-asserting the current fold value is a no-op" do
      set = set_of([agent_set("wisp", @genesis_fields, ts: @ts)])
      {:ok, view} = Config.resolve(set, "wisp")

      assert Config.changed_fields(view, %{model: "deepseek-v4-flash"}) == %{}
    end

    test "re-asserting a PREVIOUS value is a change (set A -> B -> A resolves to A)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{model: "kimi-k3"}, ts: @ts + 1)
      ]

      {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      changes = Config.changed_fields(view, %{model: "deepseek-v4-flash"})
      assert changes == %{model: "deepseek-v4-flash"}

      # append the re-assertion: the fold resolves back to A
      pairs = pairs ++ [agent_set("wisp", changes, ts: @ts + 2)]
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set_of(pairs), "wisp")
    end

    test "a nil fold (no live head) treats every field as changed" do
      assert Config.changed_fields(nil, %{model: "kimi-k3"}) == %{model: "kimi-k3"}
    end
  end

  # -------------------------------------------------------------- boot opts

  describe "Config.boot_opts/2 — fold + CLI overrides (AC4)" do
    test "the fold maps into boot opts; overrides win and never touch the fold" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{soul: "quiet", system_prompt: "You are wisp."}, ts: @ts + 1)
      ]

      {:ok, view} = Config.resolve(set_of(pairs), "wisp")

      opts = Config.boot_opts(view, [])
      assert opts[:model] == "deepseek-v4-flash"
      assert opts[:base_url] == "https://api.deepseek.com/v1"
      assert opts[:system_prompt] == "You are wisp."
      assert opts[:loop] == :reactor
      assert opts[:oracle_seed] == :absent
      assert opts[:channel_socket] == :default
      assert opts[:api_key] == {:env, "DEEPSEEK_API_KEY"}
      assert opts[:soul] == "quiet"

      overridden = Config.boot_opts(view, model: "kimi-k3")
      assert overridden[:model] == "kimi-k3"
      assert overridden[:base_url] == "https://api.deepseek.com/v1"
    end
  end
end
