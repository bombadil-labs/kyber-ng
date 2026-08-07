defmodule Kyber.Agent.Memory do
  @moduledoc """
  The memory container (T11c): gather handler + resolution authority. A
  remembered fact is never a written entity — it is a RESOLUTION over the
  delta chain (spine 2): the `MemoryEntity` deltas naming an entity plus
  every `MemoryEdited` delta that (transitively) supersedes one of them,
  ordered by time; the canon is the newest link's content.

  Provenance is part of the resolution: a canon whose head is a
  `MemoryEdited` attested `human_edit` carries `provenance: :human`;
  anything else is `:auto`. The chain-walk is the container's own — the
  schema layer's `resolve_entity/2` gathers deltas pointing AT an entity,
  but a `MemoryEdited` points at a DELTA (`edits`), never at the entity, so
  membership is transitive over the edit chain.

  The stateful face is a cache of truth (spine 6): `intake/2` takes wires
  unconditionally — no type filter; everything verified through the one door
  (`Kyber.Store.admit/2`) merges — and `rehydrate/2` rebuilds by replay
  through that same door. The pure core (`resolve_set/1`, `canon/2`,
  `trajectory/2`) answers from any delta set, so replay and tests never need
  the process.
  """

  use Agent

  alias Kyber.{DeltaSet, Schema, Store}

  @type memory :: %{
          entity: String.t(),
          content: String.t(),
          provenance: :human | :auto,
          head: String.t(),
          chain: [String.t()],
          timestamp: float()
        }

  # ------------------------------------------------------------- pure core

  @doc """
  Resolve every memory in `set`: one record per entity that has at least one
  `MemoryEntity` delta, canon and provenance from the edit chain, sorted by
  entity id (deterministic — resolution is a pure function of the set).
  `human_author` (the human key's `ed25519:` id, when boot wiring carries
  it) makes provenance signer-derived; `nil` falls back to the reason
  string (see `provenance/2`).
  """
  @spec resolve_set(DeltaSet.t(), String.t() | nil) :: [memory()]
  def resolve_set(set, human_author \\ nil) do
    {bases, edits_by_target} = classify(set)

    bases
    |> Enum.map(fn {entity_id, nodes} ->
      ordered =
        nodes
        |> grow(edits_by_target)
        |> Enum.sort_by(&{&1.ts, &1.id})

      head = List.last(ordered)

      %{
        entity: entity_id,
        content: head.content,
        provenance: provenance(head, human_author),
        head: head.id,
        chain: Enum.map(ordered, & &1.id),
        timestamp: head.ts
      }
    end)
    |> Enum.sort_by(& &1.entity)
  end

  @doc "The resolved memory for one entity, or `nil` if the set holds none."
  @spec canon(DeltaSet.t(), String.t()) :: memory() | nil
  def canon(set, entity_id) do
    set |> resolve_set() |> Enum.find(&(&1.entity == entity_id))
  end

  @doc "`canon/2` with a known human key — signer-derived provenance."
  @spec canon(DeltaSet.t(), String.t(), String.t()) :: memory() | nil
  def canon(set, entity_id, human_author) do
    set |> resolve_set(human_author) |> Enum.find(&(&1.entity == entity_id))
  end

  @doc """
  Trajectory retrieval: the time-ordered chain of a memory's resolutions,
  oldest → newest, as delta ids. An unknown entity answers `[]`.
  """
  @spec trajectory(DeltaSet.t(), String.t()) :: [String.t()]
  def trajectory(set, entity_id) do
    case canon(set, entity_id) do
      nil -> []
      %{chain: chain} -> chain
    end
  end

  # a node is one link of a chain: the delta's id, its timestamp, the
  # content it asserts, its SIGNER (authority), and (for edits) the reason
  defp classify(set) do
    Enum.reduce(set, {%{}, %{}}, fn {id, {claims, _sig}}, {bases, edits} ->
      case Schema.resolve(claims) do
        %{type: "MemoryEntity", entity: {:entity, entity_id, _}, content: content} ->
          node = %{
            id: id,
            ts: claims.timestamp,
            content: content,
            kind: :base,
            reason: nil,
            author: claims.author
          }

          {Map.update(bases, entity_id, [node], &[node | &1]), edits}

        %{type: "MemoryEdited", edits: {:delta, target, _}, content: content} = typed ->
          node = %{
            id: id,
            ts: claims.timestamp,
            content: content,
            kind: :edit,
            reason: typed.reason,
            author: claims.author
          }

          {bases, Map.update(edits, target, [node], &[node | &1])}

        _ ->
          {bases, edits}
      end
    end)
  end

  # transitive closure: an edit whose target is already in the chain joins
  # it, and edits of edits follow — merge-is-union, so a fork simply widens
  # the chain and time (then id) picks the canon
  defp grow(chain, edits_by_target) do
    ids = MapSet.new(chain, & &1.id)

    additions =
      chain
      |> Enum.flat_map(&Map.get(edits_by_target, &1.id, []))
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(ids, &1.id))

    case additions do
      [] -> chain
      new -> grow(chain ++ new, edits_by_target)
    end
  end

  # provenance is AUTHORITY, not label (fold from the T11c verdict, C's
  # best idea): the head edit's SIGNER decides — an edit signed by the human
  # key is :human even if its reason string were absent or different; an
  # edit an agent signed is :auto even if it wrote "human_edit" (the
  # spoof-proof pin B's build could not test). Until boot wiring carries the
  # human key (human_author == nil), the reason-string rule is the fallback.
  defp provenance(%{kind: :edit, author: author}, human_author) when is_binary(human_author) do
    if author == human_author, do: :human, else: :auto
  end

  defp provenance(%{kind: :edit, reason: "human_edit"}, _nil), do: :human
  defp provenance(_head, _human_author), do: :auto

  # ------------------------------------------------- the container (cache)

  @doc """
  Start a memory container holding an empty delta set. Unnamed by default so
  tests isolate; pass `name:` to register.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> Agent.start_link(&DeltaSet.new/0, name: name)
      :error -> Agent.start_link(&DeltaSet.new/0)
    end
  end

  @doc """
  Intake: verify through the one door, then merge — unconditionally (spine
  9: no type filter; the container caches everything it is fed and the
  resolution lens picks the memory vocabulary out). A refused wire leaves
  the cache untouched.
  """
  @spec intake(Agent.agent(), map()) :: :ok | {:error, term()}
  def intake(container, wire) do
    Agent.get_and_update(container, fn set ->
      case Store.admit(wire, set) do
        {:ok, new_set} -> {:ok, new_set}
        {:error, _} = err -> {err, set}
      end
    end)
  end

  @doc """
  Rehydrate by replay (spine 6): drop the cache and re-admit every wire
  through the same pure door. Refusal halts the replay and reports.
  """
  @spec rehydrate(Agent.agent(), [map()]) :: :ok | {:error, term()}
  def rehydrate(container, wires) do
    replayed =
      Enum.reduce_while(wires, {:ok, DeltaSet.new()}, fn wire, {:ok, set} ->
        case Store.admit(wire, set) do
          {:ok, new_set} -> {:cont, {:ok, new_set}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case replayed do
      {:ok, set} -> Agent.update(container, fn _ -> set end)
      {:error, _} = err -> err
    end
  end

  @doc "The container's resolved memories — the pure lens over its cached set."
  @spec memories(Agent.agent()) :: [memory()]
  def memories(container), do: Agent.get(container, &resolve_set/1)

  @doc "The container's cached delta set — for lenses that read the whole set."
  @spec set(Agent.agent()) :: DeltaSet.t()
  def set(container), do: Agent.get(container, & &1)
end
