defmodule Kyber.Schema do
  @moduledoc """
  The schema container actor (T11a): holds the compiled schema set in memory
  and is the resolution authority for the delta vocabulary — `validate/1` at
  admission (strict for declared lifecycle types, raw admission for unknown),
  `resolve/1` for typed access, `resolve_entity/2` for the bounded entity
  gather (spine 2 bridge).

  Schemas are themselves deltas. The container boots from the genesis set
  (`Kyber.Schema.Genesis`) and evolves live: `observe/1` is the subscription
  seam — feed it a schema delta's wire envelope and the relevant entry is
  recompiled without restart. Every observed schema delta goes through the
  ONE door (`Kyber.Store.verify/1`) first; there is no second door. Replacing
  a type's schema demands retraction-plus-new-issue: the new schema delta
  must `retracts` the current issue's content id — never a migration. A
  negation delta (`negates` → a schema delta's content id) retracts the
  entry — retraction-is-negation, the only other evolution. The store only
  learns; this compiled set is a lens over it, never a store property.

  When the container is not running, `validate/1` and `resolve/1` answer from
  the genesis set — the pure paths stay usable in replay and tests.
  """

  use Agent

  alias Kyber.Schema.{Compiler, Genesis}
  alias Kyber.Store

  @doc "Start the container with the genesis schema set. Singleton, like the store."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(&Genesis.compiled/0, name: __MODULE__)
  end

  @doc """
  Validate a delta's claims at admission. A declared known lifecycle type is
  checked strictly against its schema and resolved (`{:ok, typed}`);
  ill-shaped is refused (`{:error, reason}` — reject, never repair); an
  unknown or undeclared type is admitted raw (`{:ok, :raw}`).
  """
  @spec validate(term()) :: {:ok, term()} | {:ok, :raw} | {:error, term()}
  def validate(claims), do: Compiler.validate(claims, current().schemas)

  @doc """
  Typed access for handlers: the resolved typed object for a declared known
  type, `:raw` for anything else — raw deltas never saturate typed handlers.
  """
  @spec resolve(term()) :: term() | :raw | {:error, term()}
  def resolve(claims) do
    case validate(claims) do
      {:ok, :raw} -> :raw
      {:ok, typed} -> typed
      {:error, _} = err -> err
    end
  end

  @doc "The type names the container currently resolves, sorted."
  @spec known_types() :: [String.t()]
  def known_types, do: current().schemas |> Map.keys() |> Enum.sort()

  @doc """
  The bounded entity gather (spine 2, T11): every delta in `delta_set`
  pointing at `entity_id`, grouped by pointer role, plus the reading
  hyperschema that named the resolution.
  """
  @spec resolve_entity(String.t(), Kyber.DeltaSet.t()) ::
          {:ok, Compiler.hyperview()} | {:error, term()}
  def resolve_entity(entity_id, delta_set) when is_binary(entity_id) do
    Compiler.resolve_entity(entity_id, delta_set, current().hyperschemas)
  end

  @doc """
  Live evolution: observe a schema delta (wire envelope). Verified through
  the one door, compiled against the hyperschema, then swapped into the set.
  Replacing an existing type refuses unless the new issue retracts the
  current one; a negation delta retracts by content address. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec observe(map()) :: :ok | {:error, term()}
  def observe(wire) when is_map(wire) do
    if Process.whereis(__MODULE__) do
      with {:ok, %{id: id, claims: claims}} <- Store.verify(wire) do
        Agent.get_and_update(__MODULE__, fn set ->
          case recompile(claims, id, set) do
            {:ok, new_set} -> {:ok, new_set}
            {:error, _} = err -> {err, set}
          end
        end)
      end
    else
      {:error, :schema_not_running}
    end
  end

  def observe(_), do: {:error, :malformed_envelope}

  defp recompile(claims, id, set) do
    with {:ok, result} <- Compiler.compile(claims, id) do
      case result do
        {:schema, spec} ->
          with :ok <- supersession(spec, set.schemas) do
            {:ok, %{set | schemas: Map.put(set.schemas, spec.name, spec)}}
          end

        {:hyperschema, hs} ->
          with :ok <- supersession(hs, set.hyperschemas) do
            {:ok, %{set | hyperschemas: Map.put(set.hyperschemas, hs.name, hs)}}
          end

        {:negation, target} ->
          {:ok, retract(set, target)}
      end
    end
  end

  # Replay-safe supersession: re-ingesting the SAME delta and a late-arriving
  # OLDER version are both no-ops (the store only learns — a replayed chain
  # must not fail); replacing the live entry demands retraction-plus-new-issue.
  defp supersession(spec, entries) do
    case Map.fetch(entries, spec.name) do
      :error ->
        :ok

      {:ok, %{delta_id: current_id}} when current_id == spec.delta_id ->
        :ok

      {:ok, %{version: current_version}} when spec.version < current_version ->
        :ok

      {:ok, %{delta_id: current_id}} ->
        if spec.retracts == current_id,
          do: :ok,
          else: {:error, {:must_retract_current, current_id}}
    end
  end

  # Retract an entry by its defining delta's content id. Retracting a never-
  # seen id is a no-op (replay-safe — the store only learns; a replay of a
  # negation after the fact must not fail the chain).
  defp retract(set, delta_id) do
    case Enum.find(set.schemas, fn {_name, spec} -> spec.delta_id == delta_id end) do
      {name, _spec} ->
        %{set | schemas: Map.delete(set.schemas, name)}

      nil ->
        case Enum.find(set.hyperschemas, fn {_name, hs} -> hs.delta_id == delta_id end) do
          {name, _hs} -> %{set | hyperschemas: Map.delete(set.hyperschemas, name)}
          nil -> set
        end
    end
  end

  # "not running" includes DYING between the whereis and the call (an async
  # test sibling's supervised container exiting mid-resolve): fall back to
  # the genesis set, per the documented pure-path contract
  defp current do
    case Process.whereis(__MODULE__) do
      nil ->
        Genesis.compiled()

      _pid ->
        try do
          Agent.get(__MODULE__, & &1)
        catch
          :exit, _reason -> Genesis.compiled()
        end
    end
  end
end
