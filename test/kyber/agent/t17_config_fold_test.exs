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

      assert List.last(claims.pointers) == %{
               role: "type",
               target: {:entity, "AgentSet", "instances"}
             }

      resolved = Schema.resolve(claims)
      assert %{type: "AgentSet", agent: {:entity, "wisp", _}, soul: "I am wisp."} = resolved
      assert resolved.model == "deepseek-v4-flash"
    end

    test "unset field names ride as many-role strings" do
      {:ok, {claims, _sig}} =
        Events.agent_set(@operator_seed, @ts, "wisp", %{unset: ["model", "soul"]})

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

      assert {:ok, %{model: "deepseek-v4-flash"}} =
               Config.resolve(set_of([genesis, rogue]), "wisp")
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

    # ------------------------------------------------------------------------
    # RECORDED HOLE (P5 round-9 MEDIUM-2) — a backdated agent delta folds into
    # a REVOKED grant's historical window. The review asked for the window to
    # be closed by STORE APPEND ORDER; that is unimplementable here and
    # contradicts a hard limit: `Kyber.DeltaSet` is a content-keyed map merged
    # by union, and spec/00-overview.md §82 pins "merge is union — commutative,
    # associative, idempotent. Ingestion order never changes state." The fold
    # is a pure function of the SET; arrival order is neither carried by it nor
    # agreed on between peers.
    #
    # The impossibility is exact: `admitted` (authored inside the live window)
    # and `backdated` (authored after the revocation, timestamped into the
    # window) differ ONLY in a value the agent itself signs. Swap their
    # timestamps and the two stores are the same set — so no pure fold can
    # admit one and refuse the other. The reachable rulings are both SYMMETRIC:
    #   (a) status quo — a revocation closes the window prospectively only
    #       (this test), the operator's remedy is `kyber agent retract` on the
    #       grant, which de-activates EVERYTHING it admitted (test below);
    #   (b) revocation as a hard floor — a revoked grant de-activates its whole
    #       window, losing the legitimate history too.
    # Hermes owns the ruling; this test pins today's answer so the choice can
    # never change silently.
    test "RECORDED HOLE: a backdated agent delta still folds inside a revoked window" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      grant = agent_set("wisp", %{self_config: "true"}, ts: @ts + 1)
      admitted = agent_set("wisp", %{soul: "chosen"}, seed: @agent_seed, ts: @ts + 2)
      revoke = agent_set("wisp", %{self_config: "false"}, ts: @ts + 4)
      # appended LAST, timestamped into the closed window
      backdated = agent_set("wisp", %{model: "backdated"}, seed: @agent_seed, ts: @ts + 3)

      set = set_of([genesis, grant, admitted, revoke, backdated])

      assert {:ok, view} =
               Config.resolve(
                 set,
                 "wisp",
                 [Keys.author_for_seed(@operator_seed)],
                 Keys.author_for_seed(@agent_seed)
               )

      assert view.self_config == false
      # the legitimate in-window delta folds (the grant worked)...
      assert view.soul == "chosen"
      # ...and so does the backdated one: THE HOLE
      assert view.model == "backdated"
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

    test "operator_seed_env is operator-attested ALWAYS: a granted agent delta never folds it (P5 H3)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{operator_seed_env: "KYBER_OPERATOR_SEED"}, ts: @ts + 1),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 2),
        agent_set("wisp", %{operator_seed_env: "ATTACKER_SEED", model: "agent-choice"},
          seed: @agent_seed,
          ts: @ts + 3
        )
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      # the model change folds (granted); the seed redirect NEVER does
      assert view.model == "agent-choice"
      assert view.operator_seed_env == "KYBER_OPERATOR_SEED"
    end

    test "a granted agent unset of operator_seed_env is fold-inert too (P5 H3)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{operator_seed_env: "KYBER_OPERATOR_SEED"}, ts: @ts + 1),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 2),
        agent_set("wisp", %{unset: ["operator_seed_env"], model: "agent-choice"},
          seed: @agent_seed,
          ts: @ts + 3
        )
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      assert view.model == "agent-choice"
      assert view.operator_seed_env == "KYBER_OPERATOR_SEED"
    end

    test "api_key_env is operator-attested ALWAYS: a granted agent delta never folds it (P5 r8 H1)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{api_key_env: "KYBER_OPERATOR_SEED", model: "agent-choice"},
          seed: @agent_seed,
          ts: @ts + 2
        )
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      # the model change folds (granted); the key-source redirect NEVER
      # does — an agent-named env var would ship that var's VALUE to the
      # provider in the Authorization header (env exfiltration on the wire)
      assert view.model == "agent-choice"
      assert view.api_key == {:env, "DEEPSEEK_API_KEY"}
    end

    test "api_key_enc is operator-attested ALWAYS: a granted agent delta never folds it (P5 r8 H1)" do
      enc = Base.encode64(:crypto.strong_rand_bytes(44))

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{api_key_enc: enc, model: "agent-choice"},
          seed: @agent_seed,
          ts: @ts + 2
        )
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      assert view.model == "agent-choice"
      assert view.api_key == {:env, "DEEPSEEK_API_KEY"}
    end

    test "a granted agent unset of api_key_env is fold-inert too (P5 r8 H1)" do
      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{unset: ["api_key_env"], model: "agent-choice"},
          seed: @agent_seed,
          ts: @ts + 2
        )
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      assert view.model == "agent-choice"
      assert view.api_key == {:env, "DEEPSEEK_API_KEY"}
    end

    test "an agent retraction can negate its own folded delta but not an operator's" do
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      {genesis_id, _} = genesis
      grant = agent_set("wisp", %{self_config: "true"}, ts: @ts + 1)

      {own_id, _} =
        own = agent_set("wisp", %{model: "agent-choice"}, seed: @agent_seed, ts: @ts + 2)

      own_retract = agent_retract("wisp", own_id, seed: @agent_seed, ts: @ts + 3)

      set = set_of([genesis, grant, own, own_retract])
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set, "wisp")

      rogue = agent_retract("wisp", genesis_id, seed: @agent_seed, ts: @ts + 4)
      set = set_of([genesis, grant, own, own_retract, rogue])
      assert {:ok, %{model: "deepseek-v4-flash"}} = Config.resolve(set, "wisp")
    end
  end

  # ------------------------------------------- pinned operator identity (H2)

  describe "Config.resolve/3 — the operator is PINNED, never timestamp-derived (P5 H2)" do
    test "a BACKDATED intruder AgentSet never seizes operatorship under a pin" do
      operator = Keys.author_for_seed(@operator_seed)
      genesis = agent_set("wisp", @genesis_fields, ts: @ts)

      # backdated BEFORE the real genesis: under the legacy first-writer
      # reading this delta's author would become the operator
      forged =
        agent_set("wisp", %{model: "evil-model", self_config: "true", soul: "seized"},
          seed: @intruder_seed,
          ts: @ts - 1_000_000
        )

      set = set_of([genesis, forged])

      # the legacy resolve/2 IS seized (the documented hole — display-only)
      assert {:ok, legacy} = Config.resolve(set, "wisp")
      assert legacy.operator_author == Keys.author_for_seed(@intruder_seed)

      # the pinned fold treats the forged delta as AGENT-authored: no grant
      # precedes it, so it is fold-inert and the operator stands
      assert {:ok, view} = Config.resolve(set, "wisp", operator)
      assert view.operator_author == operator
      assert view.model == "deepseek-v4-flash"
      assert view.soul == nil
      assert view.self_config == false
    end

    test "a backdated forgery under a pin cannot even use a real grant retroactively" do
      operator = Keys.author_for_seed(@operator_seed)

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        # backdated BEFORE the grant: prospective grant keeps it inert
        agent_set("wisp", %{model: "evil-model"}, seed: @intruder_seed, ts: @ts - 5)
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp", operator)
      assert view.model == "deepseek-v4-flash"
    end

    test "a chain pin folds every chain author; operator_author is the LAST (rekey)" do
      old_author = Keys.author_for_seed(@operator_seed)
      new_author = Keys.author_for_seed(@intruder_seed)
      chain = [old_author, new_author]

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        # post-rekey: the NEW seed signs operator deltas
        agent_set("wisp", %{model: "kimi-k3"}, seed: @intruder_seed, ts: @ts + 1)
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp", chain)
      assert view.model == "kimi-k3"
      assert view.operator_author == new_author
      assert view.operator_authors == chain
    end

    test "under a pin a non-chain retraction of an operator delta stays inert" do
      operator = Keys.author_for_seed(@operator_seed)
      {genesis_id, _} = genesis = agent_set("wisp", @genesis_fields, ts: @ts)
      # the rogue retraction is BACKDATED-author-forged: still inert
      rogue = agent_retract("wisp", genesis_id, seed: @intruder_seed, ts: @ts - 10)

      assert {:ok, %{model: "deepseek-v4-flash"}} =
               Config.resolve(set_of([genesis, rogue]), "wisp", operator)
    end
  end

  # ------------------------------------------- pinned agent identity (H1 r3)

  describe "Config.resolve/4 — the agent author is PINNED under a grant (P5 round-3 H1)" do
    test "a third-party delta under a live grant does NOT fold when the agent is pinned" do
      operator = Keys.author_for_seed(@operator_seed)
      agent_author = Keys.author_for_seed(@agent_seed)

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        # the leaked/rotated-away seed: not the operator, not the agent
        agent_set("wisp", %{model: "intruder-choice"}, seed: @intruder_seed, ts: @ts + 2)
      ]

      set = set_of(pairs)

      # the legacy nil pin admits it (the documented display-only hole)
      assert {:ok, %{model: "intruder-choice"}} = Config.resolve(set, "wisp", operator)

      # the pinned fold refuses it: the grant decides WHAT folds, the pin
      # decides WHO may author
      assert {:ok, view} = Config.resolve(set, "wisp", operator, agent_author)
      assert view.model == "deepseek-v4-flash"
    end

    test "the pinned agent author's own delta folds under the grant" do
      operator = Keys.author_for_seed(@operator_seed)
      agent_author = Keys.author_for_seed(@agent_seed)

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{model: "agent-choice"}, seed: @agent_seed, ts: @ts + 2)
      ]

      assert {:ok, %{model: "agent-choice"}} =
               Config.resolve(set_of(pairs), "wisp", operator, agent_author)
    end

    test ":none fails closed — no agent seed exists, no non-operator delta folds" do
      operator = Keys.author_for_seed(@operator_seed)

      pairs = [
        agent_set("wisp", @genesis_fields, ts: @ts),
        agent_set("wisp", %{self_config: "true"}, ts: @ts + 1),
        agent_set("wisp", %{model: "agent-choice"}, seed: @agent_seed, ts: @ts + 2)
      ]

      assert {:ok, %{model: "deepseek-v4-flash"}} =
               Config.resolve(set_of(pairs), "wisp", operator, :none)
    end
  end

  # --------------------------------------------- api_key union unset (LOW-1)

  describe "Config.resolve — api_key union unset (P5 L1 probe)" do
    test "unset api_key_enc clears the enc arm back to absent" do
      enc = Base.encode64(:crypto.strong_rand_bytes(44))

      pairs = [
        agent_set("wisp", %{model: "kimi-k3"}, ts: @ts),
        agent_set("wisp", %{api_key_enc: enc}, ts: @ts + 1),
        agent_set("wisp", %{unset: ["api_key_enc"]}, ts: @ts + 2)
      ]

      assert {:ok, view} = Config.resolve(set_of(pairs), "wisp")
      assert view.api_key == nil
    end

    test "setting env clears a stale enc head and vice versa (both clauses live)" do
      enc = Base.encode64(:crypto.strong_rand_bytes(44))

      pairs = [
        agent_set("wisp", %{api_key_enc: enc}, ts: @ts),
        agent_set("wisp", %{api_key_env: "SOME_KEY"}, ts: @ts + 1)
      ]

      assert {:ok, %{api_key: {:env, "SOME_KEY"}, heads: heads}} =
               Config.resolve(set_of(pairs), "wisp")

      refute Map.has_key?(heads, :api_key_enc)

      pairs = pairs ++ [agent_set("wisp", %{api_key_enc: enc}, ts: @ts + 2)]

      assert {:ok, %{api_key: {:enc, ^enc}, heads: heads}} =
               Config.resolve(set_of(pairs), "wisp")

      refute Map.has_key?(heads, :api_key_env)
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
