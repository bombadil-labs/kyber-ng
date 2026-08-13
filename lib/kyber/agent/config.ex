defmodule Kyber.Agent.Config do
  @moduledoc """
  The AgentSet fold (T17): an agent's operational identity is an entity
  folded over its own `AgentSet` delta stream — no config file, the stream
  is the only truth. Deltas SET properties; the fold merges per-field with
  last-set-wins (`{timestamp, id}` order); retraction is negation and the
  fold steps back PER FIELD to the previous live setter (the safety
  harness's mechanism).

  The OPERATOR is the author of the earliest `AgentSet` delta for the name
  (the creator — `agent new` appends the genesis layer before any agent
  runs), so the fold is a pure function of the set. The H2c author filter
  applies with a PROSPECTIVE `self_config` grant: an agent-authored delta
  folds only when a live operator-attested grant precedes it in
  `{timestamp, id}` order — a pre-grant agent delta stays inert forever,
  and retracting the grant de-activates everything it admitted.
  `base_url` folds ONLY when operator-attested, regardless of the grant
  (premortem P0 — a prompt-injected agent must not point the key at an
  attacker proxy). Negations are author-filtered per target: an
  operator delta is negatable only by the operator; an agent delta by the
  operator or the agent's own author.

  Dedup is SEMANTICS-AWARE (`changed_fields/2`): re-asserting the current
  fold value is a true no-op (no delta appended); re-asserting a PREVIOUS
  value is a genuine change and must produce a new delta that re-wins the
  merge (the timestamp is part of the content address for this reason).
  """

  alias Kyber.{DeltaSet, Schema}
  alias Kyber.Agent.Liveness

  @fields ~w(soul base_url model api_key_env api_key_enc system_prompt operator_seed_env oracle_seed loop channel_socket profile self_config)a

  @type view :: %{
          name: String.t(),
          soul: String.t() | nil,
          base_url: String.t() | nil,
          model: String.t() | nil,
          api_key: {:env, String.t()} | {:enc, String.t()} | nil,
          system_prompt: String.t() | nil,
          operator_seed_env: String.t() | nil,
          oracle_seed: String.t() | nil,
          loop: String.t() | nil,
          channel_socket: String.t() | nil,
          profile: String.t() | nil,
          self_config: boolean(),
          heads: %{atom() => String.t()},
          operator_author: String.t()
        }

  @doc "The AgentSet field vocabulary (atoms, emission order fixed in Events)."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  The fold: `{:ok, view}` when the name has at least one live `AgentSet`
  delta; `:not_found` for unknown or whitespace-only names and for a fully
  retracted stream (AC16 — boot then falls through to the engine's
  hardcoded defaults). Pure, deterministic, replica-identical.
  """
  @spec resolve(DeltaSet.t(), String.t()) :: {:ok, view()} | :not_found
  def resolve(set, name) when is_binary(name) do
    if String.trim(name) == "" do
      :not_found
    else
      case collect(set, name) do
        [] ->
          :not_found

        [{_id, _resolved, first} | _] = deltas ->
          operator_author = first.author
          {acc, heads} = walk(set, deltas, operator_author)

          if acc == %{} do
            :not_found
          else
            {:ok, view(name, acc, heads, operator_author)}
          end
      end
    end
  end

  @doc """
  Semantics-aware dedup (AC8 premortem): the subset of `fields` whose
  resolved value DIFFERS from the current fold — the write path appends a
  delta only when this is non-empty. A nil fold treats every field as
  changed. `unset` names pass through only for currently-set fields.
  """
  @spec changed_fields(view() | nil, map()) :: map()
  def changed_fields(nil, fields), do: fields

  def changed_fields(view, fields) do
    {unset, sets} = Map.pop(fields, :unset, [])

    changed =
      sets
      |> Enum.reject(fn {field, value} -> current_value(view, field) == value end)
      |> Map.new()

    case Enum.filter(unset, &(current_value(view, safe_field(&1)) != nil)) do
      [] -> changed
      live_unsets -> Map.put(changed, :unset, live_unsets)
    end
  end

  @doc """
  Boot-opts resolution (AC2/AC4): the fold mapped into `Daemon.boot/1`
  opts, with CLI `overrides` merged LAST (overrides win and never append
  deltas). `api_key` stays tagged (`{:env, name} | {:enc, b64}`) — the
  value is resolved/decrypted only at the usage point.
  """
  @spec boot_opts(view(), keyword()) :: keyword()
  def boot_opts(view, overrides) do
    base = [
      model: view.model,
      base_url: view.base_url,
      system_prompt: view.system_prompt,
      soul: view.soul,
      profile: view.profile,
      api_key: view.api_key,
      operator_seed_env: view.operator_seed_env,
      loop: loop_atom(view.loop),
      oracle_seed: oracle_atom(view.oracle_seed),
      channel_socket: socket_opt(view.channel_socket),
      self_config: view.self_config
    ]

    base
    |> Enum.reject(fn {_k, v} -> v == nil end)
    |> Keyword.merge(overrides)
  end

  # ---------------------------------------------------------------- the door

  @env_name ~r/^[A-Z_][A-Z0-9_]*$/
  @seed_shaped ~r/^[0-9A-Fa-f]{64}$/
  @repair "provider keys are either referenced by env NAME (--api-key-env DEEPSEEK_API_KEY) or supplied encrypted (--api-key read from stdin, never argv)"

  @doc "The AC17 repair message — the one legible refusal every door speaks."
  @spec repair() :: String.t()
  def repair, do: @repair

  # the free-text shape scan (AC17): obvious secret shapes in soul /
  # system_prompt — sk-/api_ prefixes, >=32-char base64/hex runs, KEY= pairs
  @free_text_shapes [
    ~r/\bsk-[A-Za-z0-9_-]{8,}/,
    ~r/\bapi_[A-Za-z0-9]{8,}/,
    ~r/\bghp_[A-Za-z0-9]{8,}/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{8,}/,
    ~r/[0-9A-Fa-f]{32,}/,
    ~r/[A-Za-z0-9+\/]{32,}={0,2}(?![A-Za-z0-9+\/=])/,
    ~r/\S+=\S{16,}/
  ]

  @doc """
  The door (AC17/AC21/AC24): validate an `AgentSet` field map BEFORE any
  delta is built — the same validation on `agent new`/`set`, channel
  `set-config`, the self-config tool, and `--from` imports. Secret fields
  are env NAMES (`#{inspect(@env_name.source)}`) or well-formed ciphertext;
  a plaintext key is refused with the repair message. Free-text fields
  (soul, system_prompt) get the shape-scan plus the fail-closed
  high-entropy scan — the store never contains a plaintext key value.
  """
  @spec validate_fields(map()) :: :ok | {:error, term()}
  def validate_fields(fields) when is_map(fields) do
    Enum.reduce_while(fields, :ok, fn {field, value}, :ok ->
      case validate_field(field, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_field(field, value) when field in [:api_key_env, :operator_seed_env] do
    cond do
      not is_binary(value) -> {:error, {:invalid_field, field, @repair}}
      Regex.match?(@seed_shaped, value) -> {:error, {:invalid_field, field, @repair}}
      Regex.match?(@env_name, value) -> :ok
      true -> {:error, {:invalid_field, field, @repair}}
    end
  end

  defp validate_field(:api_key_enc, value) do
    if is_binary(value) and Kyber.Agent.Secrets.well_formed?(value) do
      :ok
    else
      {:error, {:invalid_field, :api_key_enc, @repair}}
    end
  end

  defp validate_field(field, value) when field in [:soul, :system_prompt] do
    cond do
      not is_binary(value) ->
        {:error, {:invalid_field, field, "must be text"}}

      Enum.any?(@free_text_shapes, &Regex.match?(&1, value)) ->
        {:error, {:secret_shaped, field, @repair}}

      high_entropy_token?(value) ->
        {:error, {:secret_shaped, field, @repair}}

      true ->
        :ok
    end
  end

  defp validate_field(:loop, value) when value in ["reactor", "ack"], do: :ok
  defp validate_field(:loop, _), do: {:error, {:invalid_field, :loop, "one of: reactor, ack"}}

  defp validate_field(:oracle_seed, value) when value in ["present", "absent"], do: :ok

  defp validate_field(:oracle_seed, _),
    do: {:error, {:invalid_field, :oracle_seed, "one of: present, absent"}}

  defp validate_field(:self_config, value) when value in ["true", "false"], do: :ok

  defp validate_field(:self_config, _),
    do: {:error, {:invalid_field, :self_config, "one of: true, false"}}

  defp validate_field(:unset, names) when is_list(names) do
    case Enum.reject(names, &safe_field/1) do
      [] -> :ok
      unknown -> {:error, {:invalid_field, :unset, "unknown fields: #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp validate_field(field, value)
       when field in [:model, :base_url, :channel_socket, :profile] and is_binary(value),
       do: :ok

  defp validate_field(field, _value), do: {:error, {:invalid_field, field, "unknown or malformed"}}

  # the fail-closed entropy scan (AC24 premortem): a long mixed-charset
  # token that shape rules missed — tuned so legitimate prose never trips
  defp high_entropy_token?(value) do
    value
    |> String.split(~r/\s+/)
    |> Enum.any?(fn token ->
      String.length(token) >= 40 and charset_classes(token) >= 3 and
        distinct_ratio(token) > 0.5
    end)
  end

  defp charset_classes(token) do
    [~r/[a-z]/, ~r/[A-Z]/, ~r/[0-9]/, ~r/[^A-Za-z0-9]/]
    |> Enum.count(&Regex.match?(&1, token))
  end

  defp distinct_ratio(token) do
    chars = String.graphemes(token)
    MapSet.size(MapSet.new(chars)) / length(chars)
  end

  # ---------------------------------------------------------------- the walk

  defp collect(set, name) do
    for(
      {id, {claims, _sig}} <- set,
      %{type: "AgentSet", agent: {:entity, ^name, _ctx}} = resolved <- [Schema.resolve(claims)],
      do: {id, resolved, claims}
    )
    |> Enum.sort_by(fn {id, _resolved, claims} -> {claims.timestamp, id} end)
  end

  # the ordered walk carries the PROSPECTIVE grant state: `granted` is the
  # folded self_config value at each position, so an agent delta folds only
  # under a live operator grant that PRECEDES it — and a retracted grant
  # de-activates everything it admitted (liveness is fold-time)
  defp walk(set, deltas, operator_author) do
    {acc, heads, _granted} =
      Enum.reduce(deltas, {%{}, %{}, false}, fn {id, resolved, claims}, {acc, heads, granted} ->
        cond do
          claims.author == operator_author ->
            if Liveness.live?(set, id, operator_filter(operator_author)) do
              {acc, heads} = apply_fields(acc, heads, id, resolved, :operator)
              {acc, heads, granted_after(acc)}
            else
              {acc, heads, granted}
            end

          granted ->
            if Liveness.live?(set, id, agent_filter(operator_author, claims.author)) do
              {acc, heads} = apply_fields(acc, heads, id, resolved, :agent)
              {acc, heads, granted_after(acc)}
            else
              {acc, heads, granted}
            end

          true ->
            {acc, heads, granted}
        end
      end)

    {acc, heads}
  end

  defp granted_after(acc), do: Map.get(acc, :self_config) == "true"

  defp apply_fields(acc, heads, id, resolved, source) do
    sets =
      for field <- @fields,
          value = Map.get(resolved, field),
          value != nil,
          # base_url is operator-attested ALWAYS (premortem P0)
          source == :operator or field != :base_url,
          do: {field, value}

    {acc, heads} =
      Enum.reduce(sets, {acc, heads}, fn {field, value}, {acc, heads} ->
        {acc, heads} = clear_union(acc, heads, field)
        {Map.put(acc, field, value), Map.put(heads, field, id)}
      end)

    Enum.reduce(resolved.unset, {acc, heads}, fn name, {acc, heads} ->
      case safe_field(name) do
        nil ->
          {acc, heads}

        # base_url is operator-attested ALWAYS — the unset arm too (P0):
        # an agent unset of base_url is fold-inert
        :base_url when source != :operator ->
          {acc, heads}

        field ->
          {Map.put(acc, field, nil), Map.put(heads, field, id)}
      end
    end)
  end

  # api_key is a tagged union: setting one arm clears the other
  defp clear_union(acc, heads, :api_key_env), do: {Map.delete(acc, :api_key_enc), Map.delete(heads, :api_key_enc)}
  defp clear_union(acc, heads, :api_key_enc), do: {Map.delete(acc, :api_key_env), Map.delete(heads, :api_key_env)}
  defp clear_union(acc, heads, _field), do: {acc, heads}

  # negations on an OPERATOR delta must be operator-authored (H2c)
  defp operator_filter(operator_author) do
    fn claims -> claims.author == operator_author end
  end

  # an agent delta is negatable by the operator OR its own author — never
  # a third party, and an agent can never negate an operator delta
  defp agent_filter(operator_author, agent_author) do
    fn claims -> claims.author == operator_author or claims.author == agent_author end
  end

  defp safe_field(name) when is_binary(name) do
    Enum.find(@fields, &(Atom.to_string(&1) == name))
  end

  defp safe_field(name) when is_atom(name), do: if(name in @fields, do: name)

  # ---------------------------------------------------------------- the view

  defp view(name, acc, heads, operator_author) do
    api_key =
      cond do
        acc[:api_key_env] -> {:env, acc[:api_key_env]}
        acc[:api_key_enc] -> {:enc, acc[:api_key_enc]}
        true -> nil
      end

    %{
      name: name,
      soul: acc[:soul],
      base_url: acc[:base_url],
      model: acc[:model],
      api_key: api_key,
      system_prompt: acc[:system_prompt],
      operator_seed_env: acc[:operator_seed_env],
      oracle_seed: acc[:oracle_seed],
      loop: acc[:loop],
      channel_socket: acc[:channel_socket],
      profile: acc[:profile],
      self_config: acc[:self_config] == "true",
      heads: heads,
      operator_author: operator_author
    }
  end

  defp current_value(_view, nil), do: nil

  defp current_value(view, :api_key_env) do
    case view.api_key do
      {:env, name} -> name
      _ -> nil
    end
  end

  defp current_value(view, :api_key_enc) do
    case view.api_key do
      {:enc, ciphertext} -> ciphertext
      _ -> nil
    end
  end

  defp current_value(view, :self_config), do: if(view.self_config, do: "true", else: "false")
  defp current_value(view, field), do: Map.get(view, field)

  defp loop_atom("reactor"), do: :reactor
  defp loop_atom("ack"), do: :ack
  defp loop_atom(nil), do: nil

  defp oracle_atom("present"), do: :present
  defp oracle_atom("absent"), do: :absent
  defp oracle_atom(nil), do: nil

  defp socket_opt("default"), do: :default
  defp socket_opt(other), do: other
end
