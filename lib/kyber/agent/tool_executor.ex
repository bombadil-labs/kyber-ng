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
  alias Kyber.Agent.{Events, Memory, Policy}
  alias Kyber.Agent.Action.Gate

  @doc "The stub registry: `tool:echo` answers its args."
  @spec stub_tools() :: %{String.t() => (String.t() -> String.t())}
  def stub_tools, do: %{"tool:echo" => fn args -> args end}

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
  The gather handler closure. Options: `:seed` (required), `:tools` (the
  registry, default `stub_tools/0`), `:gate` (a `Kyber.Agent.Action.Gate`,
  default an empty gate — fail closed: every call refused), `:context` (the
  boot-resolved action context the real actions require, default `%{}`),
  `:store` (thunk answering the delta set — the answer-from-the-store
  source; default the durable store when running, empty otherwise).
  """
  @spec handler(keyword()) :: Gather.handler()
  def handler(opts) do
    seed = Keyword.fetch!(opts, :seed)
    tools = Keyword.get(opts, :tools, stub_tools())
    gate = Keyword.get(opts, :gate, Gate.new())
    context = Keyword.get(opts, :context, %{})
    store = Keyword.get(opts, :store, &default_store/0)

    fn view -> Enum.flat_map(view, &execute(&1, seed, tools, gate, context, store)) end
  end

  defp execute(%{id: call_id, claims: claims}, seed, tools, gate, context, store) do
    case Schema.resolve(claims) do
      %{type: "ToolCall", tool: {:entity, tool_id, _ctx}, args: args} ->
        set = store.()

        {decision_wires, verdict} =
          decide(set, seed, claims.timestamp, call_id, tool_id, args, gate)

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
  defp decide(set, seed, ts, call_id, tool_id, args, gate) do
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
            do: policy_verdict(set, tool_id, args),
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

  # T14c D3: the two policy layers, in pinned order. A layer that does not
  # gate the tool id abstains (:allow); the first {:refuse, policy, reason,
  # epoch_id} wins the call's single GateDecision slot.
  defp policy_verdict(set, tool_id, args) do
    case url_policy(set, tool_id, args) do
      {:refuse, reason, epoch_id} ->
        {:refuse, "url_policy", reason, epoch_id}

      :allow ->
        memory_policy(set, tool_id, args)
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
  defp memory_policy(set, tool_id, args) do
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

  defp extract_entity(args) do
    case JSON.decode(args) do
      {:ok, %{"entity" => entity_id}} when is_binary(entity_id) -> {:ok, entity_id}
      _other -> :abstain
    end
  end

  # a refused URL never touches the network; no policy claim ⇒ ungoverned
  # (allow — the recorded hole, owned by the deferred governance-default
  # slice); a fork fails closed; undecodable args ⇒ the policy layer
  # abstains, deferring to the action's own validation
  defp url_policy(set, tool_id, args) do
    if tool_id in Policy.gated_tools() do
      case Policy.current(set) do
        :none ->
          :allow

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
        {result, status} = run(tools, tool_id, args, context, set)

        case Events.tool_result(seed, ts, call_id, result, status) do
          {:ok, signed} -> [Wire.envelope(signed)]
          {:error, _reason} -> []
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

  # T14c M1: "memory.read" resolves in a DEDICATED run clause over the
  # handler's :store snapshot (the store thunk's answer at decision time —
  # the executor stays a pure function of (store, call delta, state)). The
  # 1-arity stub closure's status is hardwired "ok" and the action-data MFA
  # cannot see the captured store, so `canon nil => {"", "unknown_entity"}`
  # lives HERE — a resolution outcome, never a refusal; the gate runs
  # strictly BEFORE resolution, so refused known/unknown are
  # indistinguishable (no existence oracle).
  defp run(_tools, "memory.read", args, _context, store_set) do
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

  defp run(tools, tool_id, args, context, _store_set) do
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

  # the bounded store walk stays deterministic under map ordering
  defp by_timestamp(set), do: Enum.sort_by(set, fn {_id, {claims, _sig}} -> claims.timestamp end)

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
