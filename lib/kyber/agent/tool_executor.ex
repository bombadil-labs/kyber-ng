defmodule Kyber.Agent.ToolExecutor do
  @moduledoc """
  The executor leg of the tool chain (T11b AC8, re-architected T12): a PURE
  gather handler on role `"tool"` that fires on `ToolCall` deltas (declared
  type checked — `ToolInvoked` shares the kind marker and must not fire
  it), passes every call through the permission gate BEFORE any action
  runs, and routes allow-listed calls by action name through the registry.

  Aligned by construction (T12): no action executes without a gate
  decision, and every decision is itself an attested `GateDecision` delta —
  the handler's output is `[gate_decision]` for a denied or refused call
  (NO `ToolResult` — reject, never repair) and
  `[gate_decision, tool_result]` for an allowed one.

  The registry seam (A/B): entries are either stub closures
  (`(args -> result)` — the T11b `tool:echo` shape) or action data
  (`%{description, parameters, run: {module, function}}` —
  `Kyber.Agent.Action.registry/0`). The executor maps both, and
  `tool_specs/1` renders both for the model: same `:tools` opt, same
  handler — stub and real registries are swappable behind the one seam.

  Determinism (the AC3 posture, strengthened in T12): the executor is a
  pure function of (store, call delta, state). A call whose `GateDecision`
  is already in the store is re-emitted from the store, never re-decided
  under a possibly-changed policy; an allowed call whose `ToolResult` is
  already in the store is re-emitted from the store, NEVER re-executed —
  the crash-window re-fire is byte-identical by construction. Fresh results
  claim the CALL's timestamp, so a replay before persistence still dedupes
  at the sink.

  Idempotence (the carried clause): `fs.read` / `fs.list` are idempotent;
  `fs.write` is idempotent under the same args; `sh.run` is idempotent only
  for pure commands; `http.get` is idempotent modulo the remote;
  `http.post` is NOT idempotent — the gate should hold side-effecting
  commands and posts at `prompt` / `deny`, and the store-answer rule covers
  re-fires after persistence.

  An unknown action or a raising action yields a `ToolResult` with a
  non-`"ok"` status — the chain always completes, the failure is recorded,
  never repaired.
  """

  alias Kyber.{Gather, Schema, Wire}
  alias Kyber.Agent.{Action, Config, Events, Memory, Policy, Profile, Skill, Tools}
  alias Kyber.Agent.Action.Gate

  # the fold-level twin lives in Config.apply_fields (@operator_only) — a
  # hand-appended agent delta naming these fields is fold-inert even when
  # this boundary is bypassed. The key source is here too (P5 round-8
  # HIGH-1): an agent-named api_key_env would exfiltrate any daemon-readable
  # env var to the provider via the Authorization header. So are the three
  # P5 round-10 fields: channel_socket (the daemon File.rm's the path
  # before bind — a file-deletion primitive), oracle_seed (the operator's
  # inference gate) and profile (the capability envelope).
  @operator_attested [
    :base_url,
    :operator_seed_env,
    :api_key_env,
    :api_key_enc,
    :channel_socket,
    :oracle_seed,
    :profile
  ]

  @doc "The stub registry: `tool:echo` answers its args."
  @spec stub_tools() :: %{String.t() => (String.t() -> String.t())}
  def stub_tools, do: %{"tool:echo" => fn args -> args end}

  @doc """
  T14j (C1): the workspace-aware default — the ONE implementation lives at
  `Kyber.Agent.Tools.default_tools/1` (the completion gate's
  `lib/kyber/agent/tools.ex`); this executor surface is the spec-cited
  consumer home (reactor.ex:451/:503/:510) and delegates. Returns the
  `{tools, context}` TUPLE; absent `:workspace` => stub tools + `%{}`
  context, byte-identical; explicit `:tools`/`:context` win (M1); the
  tools value is ALWAYS a MAP (M5).
  """
  @spec default_tools(keyword()) :: {map(), map()}
  def default_tools(opts), do: Tools.default_tools(opts)

  @doc """
  OpenAI function specs for the registry (native tool calling, B's
  posture): the model sees a sanitized name (`tool_echo`, `fs_read`), the
  registry keeps the action id; `tool_key_map/1` maps names back. Action
  data entries carry their own `parameters`; stub closures take one `args`
  string parameter.
  """
  @spec tool_specs(%{optional(String.t()) => term()}) :: [map()]
  def tool_specs(registry \\ stub_tools()) do
    for {key, entry} <- registry do
      %{
        "type" => "function",
        "function" => %{
          "name" => tool_name(key),
          "description" => description(key, entry),
          "parameters" => parameters(entry)
        }
      }
    end
  end

  @doc "Registry key -> OpenAI tool name (colons and dots are not valid function-name characters)."
  @spec tool_name(String.t()) :: String.t()
  def tool_name(key), do: key |> String.replace(":", "_") |> String.replace(".", "_")

  @doc """
  OpenAI tool name -> registry key, syntactically (`_` -> `:`, the T11b
  stub shape). Action ids with dots need the registry-accurate
  `tool_key_map/1` — the engine carries it as `:tool_keys`.
  """
  @spec tool_key(String.t()) :: String.t()
  def tool_key(name), do: String.replace(name, "_", ":")

  @doc "The registry-accurate name -> key map (dots and colons both sanitize to `_`)."
  @spec tool_key_map(%{optional(String.t()) => term()}) :: %{String.t() => String.t()}
  def tool_key_map(registry), do: Map.new(registry, fn {key, _entry} -> {tool_name(key), key} end)

  @doc """
  The memory-tool registry listing (T14c M1): `memory.read` for
  `tool_specs`/`tool_key_map` ONLY — the gate fires on tool_id membership
  regardless of registry origin, and the executor resolves reads in the
  dedicated `run` clause over the handler's store snapshot (a 1-arity stub
  closure's status is hardwired `"ok"` and the action-data MFA cannot see
  the captured store, so `canon nil => {"", "unknown_entity"}` lives in
  that clause). `store_fn` is accepted for the pinned shape — the listing
  itself carries no store access.
  """
  @spec memory_tools(fun()) :: %{String.t() => map()}
  def memory_tools(_store_fn) do
    %{
      "memory.read" => %{
        description: "Read the memory canon for an entity.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "entity" => %{
              "type" => "string",
              "description" => "The entity id whose memory canon to read."
            }
          },
          "required" => ["entity"]
        }
      }
    }
  end

  @doc """
  The skill-tool registry listing (T14f D7): `skill.set` / `skill.retract` /
  `skill.read` for `tool_specs`/`tool_key_map` ONLY — the gate fires on
  tool_id membership regardless of registry origin (the url/memory policy
  layers abstain on skill ids by membership), and the executor resolves
  reads in the dedicated `run` clause over the handler's store snapshot.
  The write tools mint their SkillSet/SkillRetract deltas in the dedicated
  `write_and_run` clause (D10/M6) — the listing itself carries no store
  access.
  """
  @spec skill_tools(fun()) :: %{String.t() => map()}
  def skill_tools(_store_fn) do
    %{
      "skill.set" => %{
        description:
          "Create or update a skill: name, description, body, optional metadata JSON string.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "The skill name (the aggregate key)."
            },
            "description" => %{"type" => "string", "description" => "What the skill is for."},
            "body" => %{"type" => "string", "description" => "The procedure."},
            "metadata" => %{
              "type" => "string",
              "description" => "Optional JSON-string metadata."
            }
          },
          "required" => ["name", "description", "body"]
        }
      },
      "skill.retract" => %{
        description: "Remove a skill (a delta-ID-targeted negation of its head set-delta).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "The skill name to remove."}
          },
          "required" => ["name"]
        }
      },
      "skill.read" => %{
        description: "Read a skill's current view (the fold over its deltas).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "The skill name to read."}
          },
          "required" => ["name"]
        }
      }
    }
  end

  @doc """
  The self-config tool listing (T17 AC5/AC9): `self_config.set` for
  `tool_specs`/`tool_key_map` ONLY — the write itself lives in the
  dedicated `write_and_run` clause, where the grant (`self_config: true`
  on the live fold), the `@operator_attested` refusal (set AND unset), and
  the AC17 door all run BEFORE any mint. The agent name rides in the handler
  `:context` (`%{agent: name}`), not in the listing.
  """
  @spec self_config_tools(String.t()) :: %{String.t() => map()}
  def self_config_tools(agent) when is_binary(agent) do
    %{
      "self_config.set" => %{
        description:
          "Update your own agent configuration (#{agent}). fields is an object over " <>
            "#{Enum.join(Enum.map(Config.fields(), &Atom.to_string/1), ", ")} plus an " <>
            "optional \"unset\" list of field names. These are operator-only: " <>
            "#{Enum.map_join(@operator_attested, ", ", &Atom.to_string/1)}. " <>
            "Secret fields take env NAMES, never key values.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "fields" => %{
              "type" => "object",
              "description" =>
                "The field changes: string values per field name, plus optional " <>
                  "\"unset\": [field names]."
            }
          },
          "required" => ["fields"]
        }
      }
    }
  end

  @doc """
  The gather handler closure. Options: `:seed` (required), `:tools` (the
  registry, default `stub_tools/0`), `:gate` (a `Kyber.Agent.Action.Gate`,
  default an empty gate — fail closed: every call refused), `:context` (the
  boot-resolved action context the real actions require, default `%{}`),
  `:store` (thunk answering the delta set — the answer-from-the-store
  source; default the durable store when running, empty otherwise),
  `:boot` (T14g R1/M2 — the boot context `{profile | nil, operator_author |
  nil}`; under a profile the tool-side policy layers source their epochs
  from the profile's families — the derived fail-closed defaults).
  """
  @spec handler(keyword()) :: Gather.handler()
  def handler(opts) do
    seed = Keyword.fetch!(opts, :seed)
    tools = Keyword.get(opts, :tools, stub_tools())
    gate = Keyword.get(opts, :gate, Gate.new())
    context = Keyword.get(opts, :context, %{})
    store = Keyword.get(opts, :store, &default_store/0)
    boot = Keyword.get(opts, :boot, {nil, nil})

    fn view -> Enum.flat_map(view, &execute(&1, seed, tools, gate, context, store, boot)) end
  end

  defp execute(%{id: call_id, claims: claims}, seed, tools, gate, context, store, boot) do
    case Schema.resolve(claims) do
      %{type: "ToolCall", tool: {:entity, tool_id, _ctx}, args: args} ->
        set = store.()

        {decision_wires, verdict} =
          decide(set, seed, claims.timestamp, call_id, tool_id, args, gate, boot)

        case verdict do
          :allow ->
            decision_wires ++
              result_wires(set, seed, claims.timestamp, call_id, tool_id, args, tools, context)

          _denied_or_refused ->
            # reject, never repair: a refused call emits NO ToolResult
            decision_wires
        end

      _not_a_tool_call ->
        []
    end
  end

  # the store is the state: a persisted decision is re-emitted verbatim
  # (byte-identical), never re-decided
  defp decide(set, seed, ts, call_id, tool_id, args, gate, boot) do
    case stored_gate_decision(set, call_id) do
      {wire, verdict} ->
        {[wire], verdict}

      nil ->
        decision = Gate.decide(gate, tool_id, args)

        # the policy layers (T14b url_policy, T14c memory_policy) see only
        # permitted calls: AFTER the permission gate allows, BEFORE any
        # execution. The decide-chain order is pinned: Gate.decide ->
        # url_policy -> memory_policy -> execute — layers disjoint by tool
        # id; memory_policy appended LAST because existing refusal
        # precedence is regression-frozen and appending is the only order
        # that provably cannot perturb the T14a/T14b suite. The FIRST
        # refusal claims the call's single GateDecision slot.
        policy_verdict =
          if decision.verdict == :allow,
            do: policy_verdict(set, tool_id, args, boot),
            else: :allow

        case policy_verdict do
          {:refuse, policy, reason, epoch_id} ->
            case Events.gate_decision(seed, ts, call_id, "refuse", policy, reason, epoch_id) do
              {:ok, signed} -> {[Wire.envelope(signed)], :refuse}
              {:error, _reason} -> {[], :refuse}
            end

          :allow ->
            case Events.gate_decision(
                   seed,
                   ts,
                   call_id,
                   to_string(decision.verdict),
                   to_string(decision.policy),
                   decision.reason
                 ) do
              {:ok, signed} -> {[Wire.envelope(signed)], decision.verdict}
              {:error, _reason} -> {[], :refuse}
            end
        end
    end
  end

  # T14c D3 / T14f L1: the three policy layers, in pinned order. A layer
  # that does not gate the tool id abstains (:allow); the first {:refuse,
  # policy, reason, epoch_id} wins the call's single GateDecision slot.
  # skill_policy is appended LAST — the precedence chain is
  # regression-frozen and appending is the only order that provably cannot
  # perturb the existing suite (layers are disjoint by tool id).
  defp policy_verdict(set, tool_id, args, boot) do
    # url_policy answers the bare {:refuse, reason, epoch_id} (the policy
    # name is pinned HERE); memory_policy and skill_policy answer the full
    # {:refuse, policy, reason, epoch_id} and pass through as-is
    case url_policy(set, tool_id, args) do
      {:refuse, reason, epoch_id} ->
        {:refuse, "url_policy", reason, epoch_id}

      :allow ->
        case memory_policy(set, tool_id, args, boot) do
          {:refuse, _policy, _reason, _epoch_id} = refusal ->
            refusal

          :allow ->
            skill_policy(set, tool_id, args, boot)
        end
    end
  end

  # the memory_policy layer (T14c D3), mirroring url_policy/3 clause for
  # clause: ungated tool => :allow; ungoverned store => FAIL-CLOSED refusal
  # (the memory tool is born in this slice with no legacy behavior to
  # preserve — the URL family's fail-open ungoverned default is recorded
  # debt, not precedent); forked epoch => fail closed; undecodable args =>
  # the policy layer abstains (action validation owns it — the
  # fork×undecodable cell is T14d's); zero allow_entity pointers => the
  # check refuses everything.
  defp memory_policy(set, tool_id, args, {nil, _author}) do
    if tool_id in Policy.memory_gated_tools() do
      case Policy.memory_epoch(set) do
        :none ->
          {:refuse, "memory_policy", Policy.reason_memory_ungoverned(), nil}

        {:error, :forked} ->
          {:refuse, "memory_policy", Policy.reason_memory_forked(), nil}

        {:ok, epoch} ->
          case extract_entity(args) do
            :abstain ->
              :allow

            {:ok, entity_id} ->
              case Policy.check_memory(epoch, entity_id) do
                :allow -> :allow
                {:refuse, reason} -> {:refuse, "memory_policy", reason, epoch.id}
              end
          end
      end
    else
      :allow
    end
  end

  # T14g (M2): under a profile the epoch source is the PROFILE's families
  # (the derived fail-closed defaults) — the union governs the check; an
  # unseeded/forked family contributes nothing (omit-all, never fail-open).
  # The refusal REASON STRINGS are the existing spellings — zero new reason
  # strings; the union epoch has no single id, so the policy_epoch pointer
  # rides nil (the optional pointer, omitted at the builder).
  defp memory_policy(set, tool_id, args, {profile_name, operator_author}) do
    if tool_id in Policy.memory_gated_tools() do
      case Profile.resolve(set, operator_author, profile_name) do
        {:ok, view} ->
          {:ok, epoch} = Profile.memory_epoch(set, view)

          case extract_entity(args) do
            :abstain ->
              :allow

            {:ok, entity_id} ->
              case Policy.check_memory(epoch, entity_id) do
                :allow -> :allow
                {:refuse, reason} -> {:refuse, "memory_policy", reason, nil}
              end
          end

        # unreachable at boot (attach refuses unknown profiles); fail-closed
        # if the fold changed under us
        :not_found ->
          {:refuse, "memory_policy", Policy.reason_memory_ungoverned(), nil}
      end
    else
      :allow
    end
  end

  # the skill_policy layer (T14f D5/M5), mirroring memory_policy clause for
  # clause: ungated tool => :allow; ungoverned store => FAIL-CLOSED refusal;
  # forked epoch => fail closed; undecodable args => the policy layer
  # abstains (action validation owns it); zero allow_entity pointers => the
  # check refuses everything. skill.set AND skill.retract are BOTH gated (a
  # retraction is a write to the same aggregate, N6) and skill.read is
  # gated like memory.read.
  defp skill_policy(set, tool_id, args, {nil, _author}) do
    if tool_id in Policy.skill_gated_tools() do
      case Policy.skill_epoch(set) do
        :none ->
          {:refuse, "skill_policy", Policy.reason_skill_ungoverned(), nil}

        {:error, :forked} ->
          {:refuse, "skill_policy", Policy.reason_skill_forked(), nil}

        {:ok, epoch} ->
          case extract_skill_name(args) do
            :abstain ->
              :allow

            {:ok, name} ->
              case Policy.check_skill(epoch, name) do
                :allow -> :allow
                {:refuse, reason} -> {:refuse, "skill_policy", reason, epoch.id}
              end
          end
      end
    else
      :allow
    end
  end

  # T14g (M2): the profile-aware skill layer — same shape as memory_policy's
  # profile clause; the epoch source is the profile's families.
  defp skill_policy(set, tool_id, args, {profile_name, operator_author}) do
    if tool_id in Policy.skill_gated_tools() do
      case Profile.resolve(set, operator_author, profile_name) do
        {:ok, view} ->
          {:ok, epoch} = Profile.skill_epoch(set, view)

          case extract_skill_name(args) do
            :abstain ->
              :allow

            {:ok, name} ->
              case Policy.check_skill(epoch, name) do
                :allow -> :allow
                {:refuse, reason} -> {:refuse, "skill_policy", reason, nil}
              end
          end

        :not_found ->
          {:refuse, "skill_policy", Policy.reason_skill_ungoverned(), nil}
      end
    else
      :allow
    end
  end

  defp extract_skill_name(args) do
    case JSON.decode(args) do
      {:ok, %{"name" => name}} when is_binary(name) -> {:ok, name}
      _other -> :abstain
    end
  end

  defp extract_entity(args) do
    case JSON.decode(args) do
      {:ok, %{"entity" => entity_id}} when is_binary(entity_id) -> {:ok, entity_id}
      _other -> :abstain
    end
  end

  # a refused URL never touches the network; no policy claim ⇒ ungoverned
  # FAIL-CLOSED (T14e: the T14d fail-open hole is closed — mirroring the
  # memory family's :none row, which precedes args decode: url args are
  # never examined under :none); a fork fails closed; undecodable args ⇒
  # the policy layer abstains, deferring to the action's own validation
  defp url_policy(set, tool_id, args) do
    if tool_id in Policy.gated_tools() do
      case Policy.current(set) do
        :none ->
          {:refuse, Policy.reason_url_ungoverned(), nil}

        {:error, :forked} ->
          {:refuse, Policy.reason_forked(), nil}

        {:ok, epoch} ->
          case extract_url(args) do
            :abstain ->
              :allow

            {:ok, url} ->
              case Policy.check(epoch, url) do
                :allow -> :allow
                {:refuse, reason} -> {:refuse, reason, epoch.id}
              end
          end
      end
    else
      :allow
    end
  end

  defp extract_url(args) do
    case JSON.decode(args) do
      {:ok, %{"url" => url}} when is_binary(url) -> {:ok, url}
      _other -> :abstain
    end
  end

  defp result_wires(set, seed, ts, call_id, tool_id, args, tools, context) do
    case stored_tool_result(set, call_id) do
      nil ->
        # T14f D10/M6: a write tool emits its store delta BEFORE the
        # ToolResult — wire order [gate_decision, skill_set, tool_result].
        {write_wires, result, status} =
          write_and_run(set, seed, ts, call_id, tool_id, args, tools, context)

        case Events.tool_result(seed, ts, call_id, result, status) do
          {:ok, signed} -> write_wires ++ [Wire.envelope(signed)]
          {:error, _reason} -> write_wires
        end

      {wire, result_id} ->
        # answer from the store — the action is NEVER re-executed; the
        # duplicate is observed (T14b): same ts + ids ⇒ same observation
        # id, so merge-is-union collapses to exactly one record per
        # (call, result) pair. Answer first.
        case Events.tool_call_duplicate(seed, ts, call_id, result_id) do
          {:ok, signed} -> [wire, Wire.envelope(signed)]
          {:error, _reason} -> [wire]
        end
    end
  end

  # the write path (T14f): skill.set / skill.retract mint their store
  # deltas and hand back {write_wires, result, status}; every other tool
  # runs uncapped with no store delta. The mints claim the CALL's
  # `claims.timestamp` — never a fresh clock — so a crash-window re-fire
  # re-mints the SAME delta and record-dedupe by content address holds
  # (M6); a replayed write is absorbed, never re-applied.
  defp write_and_run(_set, seed, ts, call_id, "skill.set", args, _tools, _context) do
    case decode_set_args(args) do
      {:ok, name, description, body, metadata} ->
        case Events.skill_set(seed, ts, name, description, body, metadata, call_id) do
          {:ok, signed} -> {[Wire.envelope(signed)], "set skill " <> name, "ok"}
          {:error, reason} -> {[], "skill set refused: " <> inspect(reason), "error"}
        end

      {:error, reason} ->
        {[], reason, "error"}
    end
  end

  defp write_and_run(set, seed, ts, _call_id, "skill.retract", args, _tools, _context) do
    case decode_name(args) do
      {:ok, name} ->
        case Skill.view(set, name) do
          # D8/L5: retract-of-unknown is a RESOLUTION OUTCOME — no negation
          # is minted (tool-boundary discipline; dangling negations would be
          # door-admissible but this surface mints none), spelled
          # {"", "unknown_entity"}
          :not_found ->
            {[], "", "unknown_entity"}

          {:ok, view} ->
            # the negation targets the ORDER-HEAD set-delta — never a name,
            # never the prior version (no retraction-path rollback)
            case Events.skill_retract(seed, ts, name, view.head) do
              {:ok, signed} -> {[Wire.envelope(signed)], "retracted skill " <> name, "ok"}
              {:error, reason} -> {[], "skill retract refused: " <> inspect(reason), "error"}
            end
        end

      {:error, reason} ->
        {[], reason, "error"}
    end
  end

  # T17 AC5/AC9 — the agent's own (opt-in) write path onto its AgentSet
  # stream. The boundary contract, in order: the @operator_attested fields
  # are refused ALWAYS (set AND unset, checked before the grant so the
  # refusal names the operator regardless); the grant (`self_config: true` on the
  # LIVE fold) is checked at call time, not boot time; the AC17 door
  # (Config.validate_fields — secret shapes, unknown fields) runs before
  # any mint. A refusal mints NO delta. The mint claims the CALL's
  # timestamp (M6 crash-window dedupe) and the AGENT's seed — the delta
  # folds only while the grant is live (prospective, negatable).
  defp write_and_run(set, seed, ts, _call_id, "self_config.set", args, _tools, context) do
    with {:agent, agent} when is_binary(agent) <- {:agent, context[:agent]},
         {:ok, fields} <- decode_self_config_args(args),
         :ok <- refuse_operator_attested(fields),
         :ok <-
           self_config_granted(set, agent, context[:operator_authors], context[:agent_author]),
         :ok <- door(fields) do
      case Events.agent_set(seed, ts, agent, fields) do
        {:ok, signed} -> {[Wire.envelope(signed)], "updated config for " <> agent, "ok"}
        {:error, reason} -> {[], "self_config refused: " <> inspect(reason), "error"}
      end
    else
      {:agent, _missing} -> {[], "self_config.set requires an agent context", "error"}
      {:error, reason} -> {[], reason, "error"}
    end
  end

  defp write_and_run(set, _seed, _ts, _call_id, tool_id, args, tools, context) do
    {result, status} = run(tools, tool_id, args, context, set)
    {[], result, status}
  end

  defp decode_self_config_args(args) do
    with {:ok, %{"fields" => raw}} when is_map(raw) <- JSON.decode(args),
         {:ok, fields} <- atomize_self_config_fields(raw) do
      {:ok, fields}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "malformed action arguments: " <> args}
    end
  end

  defp atomize_self_config_fields(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn
      {"unset", names}, {:ok, acc} when is_list(names) ->
        {:cont, {:ok, Map.put(acc, :unset, names)}}

      {"unset", _malformed}, {:ok, _acc} ->
        {:halt, {:error, "unset must be a list of field names"}}

      {name, value}, {:ok, acc} ->
        case Enum.find(Config.fields(), &(Atom.to_string(&1) == name)) do
          nil -> {:halt, {:error, "unknown field: " <> name}}
          field -> {:cont, {:ok, Map.put(acc, field, value)}}
        end
    end)
  end

  defp refuse_operator_attested(fields) do
    unset = Map.get(fields, :unset, [])

    case Enum.find(@operator_attested, fn field ->
           Map.has_key?(fields, field) or
             Enum.any?(unset, &(to_string(&1) == Atom.to_string(field)))
         end) do
      nil ->
        :ok

      field ->
        {:error, "#{field} is operator-attested — only the operator can set or unset it"}
    end
  end

  # P5 MEDIUM-2: the grant is read through the PINNED operator chain when
  # the boot threads one (context[:operator_authors]) — unpinned resolve/2
  # is display-only, and a backdated first-author delta could grant itself
  # under it. The agent-author pin rides along (P5 HIGH-1) so the grant
  # read matches the daemon's own fold. nil pins => legacy fallback
  # (chainless handler tests).
  defp self_config_granted(set, agent, operators, agent_author) do
    case Config.resolve(set, agent, operators, agent_author) do
      {:ok, %{self_config: true}} -> :ok
      _other -> {:error, "no live self_config grant for " <> agent}
    end
  end

  defp door(fields) do
    case Config.validate_fields(fields) do
      :ok -> :ok
      {:error, {_kind, field, message}} -> {:error, "#{field}: #{message}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # N1 (T14f): the trim-reject lives at the TOOL BOUNDARY — skill.set
  # refuses whitespace-only names (reject, never repair; the stored name is
  # never normalized). "" is refused too (the substrate floor refuses empty
  # entity ids — same boundary). metadata must be a string when present.
  # T14j (C5/M6): the degenerate-short-name class — the boundary refuses
  # names under N = 4 BYTES POST-TRIM (`byte_size(String.trim(name))`; the
  # assoc.ex ≥4-byte token floor is the derivation anchor — the boundary and
  # the tokenizer speak the same units). The STORED name is never
  # normalized: a whitespace-padded name is refused at the boundary (1
  # trimmed byte), never rewritten.
  @min_name_bytes 4

  defp decode_set_args(args) do
    case JSON.decode(args) do
      {:ok, %{"name" => name, "description" => description, "body" => body} = map}
      when is_binary(name) and is_binary(description) and is_binary(body) ->
        cond do
          String.trim(name) == "" ->
            {:error, "skill name must not be whitespace-only"}

          byte_size(String.trim(name)) < @min_name_bytes ->
            {:error, "skill name must be at least #{@min_name_bytes} bytes after trimming"}

          true ->
            case map do
              %{"metadata" => metadata} when is_binary(metadata) ->
                {:ok, name, description, body, metadata}

              %{"metadata" => nil} ->
                # JSON null decodes to nil — an explicit null is an absent
                # optional, not a malformed one
                {:ok, name, description, body, nil}

              %{"metadata" => _non_string} ->
                {:error, "malformed action arguments: " <> args}

              _no_metadata ->
                {:ok, name, description, body, nil}
            end
        end

      _other ->
        {:error, "malformed action arguments: " <> args}
    end
  end

  defp decode_name(args) do
    case JSON.decode(args) do
      {:ok, %{"name" => name}} when is_binary(name) -> {:ok, name}
      _other -> {:error, "malformed action arguments: " <> args}
    end
  end

  # T14d D6 — the fs.read OUTPUT cap: an executor fs.read-keyed clause over
  # the context's :output_cap (65_536 by construction at action.ex — the
  # cap's ONE home; tests inject 1024). A past-cap "ok" result truncates
  # with the house "\n" joiner + Action.truncation_marker; at exactly the
  # cap, untruncated, NO marker; a refusal/error is NEVER truncated (the
  # pinned "refused: ..." spelling survives verbatim). The executor clause
  # (not an Action.Fs edit) is the licensed home — a uniform executor cap
  # would re-truncate self-capped actions' marker tails.
  defp run(tools, "fs.read", args, context, store_set) do
    case run_uncapped(tools, "fs.read", args, context, store_set) do
      {result, "ok"} when is_binary(result) ->
        case context[:output_cap] do
          cap when is_integer(cap) and byte_size(result) > cap ->
            {binary_part(result, 0, cap) <> "\n" <> Action.truncation_marker(cap), "ok"}

          _within_or_uncapped ->
            {result, "ok"}
        end

      other ->
        other
    end
  end

  # T14d D7 — the fs.list ENTRY cap: 1024 (the ONE new literal), first 1024
  # of the SORTED listing (the sort pre-exists at fs.ex) + the count-worded
  # marker, status "ok". The B2 newline-in-filename edge (a name containing
  # "\n" breaks the line grammar, counting as two entries) is RECORDED, not
  # handled — a later fix is a visible diff, never a silent drift.
  @fs_list_cap 1024
  @fs_list_marker "[truncated: listing exceeded the #{@fs_list_cap}-entry cap]"

  defp run(tools, "fs.list", args, context, store_set) do
    case run_uncapped(tools, "fs.list", args, context, store_set) do
      {listing, "ok"} when is_binary(listing) ->
        case String.split(listing, "\n") do
          entries when length(entries) > @fs_list_cap ->
            {Enum.take(entries, @fs_list_cap)
             |> Enum.join("\n")
             |> Kernel.<>("\n" <> @fs_list_marker), "ok"}

          _within_cap ->
            {listing, "ok"}
        end

      other ->
        other
    end
  end

  defp run(tools, tool_id, args, context, store_set),
    do: run_uncapped(tools, tool_id, args, context, store_set)

  # the uncapped run path — the memory.read resolution clause and the
  # registry routing (the fs bounds clauses cap above, then delegate here)
  # T14c M1: "memory.read" resolves in a DEDICATED run clause over the
  # handler's :store snapshot (the store thunk's answer at decision time —
  # the executor stays a pure function of (store, call delta, state)). The
  # 1-arity stub closure's status is hardwired "ok" and the action-data MFA
  # cannot see the captured store, so `canon nil => {"", "unknown_entity"}`
  # lives HERE — a resolution outcome, never a refusal; the gate runs
  # strictly BEFORE resolution, so refused known/unknown are
  # indistinguishable (no existence oracle).
  defp run_uncapped(_tools, "memory.read", args, _context, store_set) do
    case JSON.decode(args) do
      {:ok, %{"entity" => entity_id}} when is_binary(entity_id) ->
        case Memory.canon(store_set, entity_id) do
          nil -> {"", "unknown_entity"}
          %{content: content} -> {content, "ok"}
        end

      _other ->
        {"malformed action arguments: " <> args, "error"}
    end
  end

  # T14f: "skill.read" resolves in a DEDICATED run clause over the handler's
  # :store snapshot — the fold IS the answer (a skill is a view, never a
  # blob). A live fold renders deterministically; an unknown OR retracted
  # skill resolves {"", "unknown_entity"} (D8 — retracted ≡ never-existed
  # at this surface, a resolution outcome, never a refusal; the gate runs
  # strictly BEFORE resolution).
  defp run_uncapped(_tools, "skill.read", args, _context, store_set) do
    case JSON.decode(args) do
      {:ok, %{"name" => name}} when is_binary(name) ->
        case Skill.view(store_set, name) do
          :not_found -> {"", "unknown_entity"}
          {:ok, view} -> {render_view(view), "ok"}
        end

      _other ->
        {"malformed action arguments: " <> args, "error"}
    end
  end

  defp run_uncapped(tools, tool_id, args, context, _store_set) do
    case Map.fetch(tools, tool_id) do
      {:ok, fun} when is_function(fun, 1) ->
        try do
          {fun.(args), "ok"}
        rescue
          e -> {Exception.message(e), "error"}
        end

      {:ok, %{run: {module, function}}} ->
        case decode_args(args) do
          {:ok, decoded} ->
            try do
              case apply(module, function, [decoded, context]) do
                {result, status} when is_binary(result) and is_binary(status) ->
                  {result, status}

                other ->
                  {"malformed action result: " <> inspect(other), "error"}
              end
            rescue
              e -> {Exception.message(e), "error"}
            end

          :error ->
            {"malformed action arguments: " <> args, "error"}
        end

      {:ok, _malformed_entry} ->
        {"malformed registry entry for " <> tool_id, "error"}

      :error ->
        {"unknown tool " <> tool_id, "unknown_tool"}
    end
  end

  # the fold rendered deterministically for the tool surface — the model
  # reads the whole current view (no wall-clock, no raw stream)
  defp render_view(view) do
    JSON.encode!(%{
      "name" => view.name,
      "description" => view.description,
      "body" => view.body,
      "metadata" => view.metadata,
      "version" => view.version,
      "head" => view.head
    })
  end

  # action args are the arguments JSON object; anything else is a recorded
  # failure, never a repair
  defp decode_args(args) do
    case JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> :error
    end
  end

  defp stored_gate_decision(set, call_id) do
    set
    |> by_timestamp()
    |> Enum.find_value(fn {_id, {claims, sig}} ->
      case Schema.resolve(claims) do
        %{type: "GateDecision", decides: {:delta, ^call_id, _ctx}, verdict: verdict} ->
          {Wire.envelope({claims, sig}), String.to_existing_atom(verdict)}

        _other ->
          nil
      end
    end)
  end

  defp stored_tool_result(set, call_id) do
    set
    |> by_timestamp()
    |> Enum.find_value(fn {id, {claims, sig}} ->
      case Schema.resolve(claims) do
        %{type: "ToolResult", call: {:delta, ^call_id, _ctx}} ->
          {Wire.envelope({claims, sig}), id}

        _other ->
          nil
      end
    end)
  end

  # the bounded store walk stays deterministic under map ordering. T14j
  # (NEW-1 / R1-C): the read is {ts, id}-TIE-BROKEN — ts-only first-match is
  # nondeterministic under the >32-entry filler regime (hash-map order
  # decides tied-ts records); {ts, id} is the substrate's total order, so
  # the dedupe read is replica-identical.
  defp by_timestamp(set),
    do: Enum.sort_by(set, fn {id, {claims, _sig}} -> {claims.timestamp, id} end)

  defp description(_key, %{description: description}), do: description

  defp description(key, _stub),
    do: "Runs " <> key <> " with its arguments and returns the result."

  defp parameters(%{parameters: parameters}), do: parameters

  defp parameters(_stub) do
    %{
      "type" => "object",
      "properties" => %{"args" => %{"type" => "string"}},
      "required" => ["args"]
    }
  end

  # the store thunk default: the durable store when it runs, empty otherwise
  # (tests inject their own; a store-less handler decides fresh every time)
  defp default_store do
    case Process.whereis(Kyber.DurableStore) do
      nil -> %{}
      _pid -> Kyber.DurableStore.set()
    end
  end
end
