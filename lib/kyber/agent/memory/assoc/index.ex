defmodule Kyber.Agent.Memory.Assoc.Index do
  @moduledoc """
  The derived edge index (T13): a unified tagged-feature space over the
  store's resolved memories, rebuilt deterministically per retrieve call — a
  pure one-pass fold over the delta set, no incremental cache, no orphan
  parking (the T11c verdict binds).

  Features of an entity's canon:

    * `{:target, source_delta_id}` — each id in the canon's source pointers
    * `{:cite, citing_delta_id}` — a delta whose `memoryPointers` /
      `memoryUsed` cites the entity's head
    * `{:session, session_id}` — the session of each source delta
    * `{:digest, hex}` — SHA-256 digests of the canon's content tokens
      (`Kyber.Agent.Memory.Assoc.digests/1`) — never prose matching

  Association is a retrieval POLICY, never a truth-maker: every edge is a
  deterministic store read; the canon stays the canon.
  """

  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.Assoc
  alias Kyber.DeltaSet

  @type feature ::
          {:target, String.t()}
          | {:cite, String.t()}
          | {:session, String.t()}
          | {:digest, String.t()}

  @type t :: %{
          by_feature: %{feature() => MapSet.t(String.t())},
          by_entity: %{String.t() => MapSet.t(feature())},
          canons: %{String.t() => Memory.memory()}
        }

  @doc "Build the index from a delta set — a pure fold, byte-identical on re-fire."
  @spec build(DeltaSet.t()) :: t()
  def build(set) do
    memories = Memory.resolve_set(set)
    canons = Map.new(memories, &{&1.entity, &1})
    head_owner = Map.new(memories, &{&1.head, &1.entity})

    {sessions, cites} =
      Enum.reduce(set, {%{}, %{}}, fn {id, {claims, _sig}}, {sessions, cites} ->
        {session_in(claims, id, sessions), cites_in(claims, id, head_owner, cites)}
      end)

    by_entity =
      Map.new(memories, fn memory ->
        {memory.entity, features(memory, set, sessions, cites)}
      end)

    by_feature =
      for {entity, features} <- by_entity,
          feature <- features,
          reduce: %{} do
        acc -> Map.update(acc, feature, MapSet.new([entity]), &MapSet.put(&1, entity))
      end

    %{by_feature: by_feature, by_entity: by_entity, canons: canons}
  end

  @doc "Document frequency of a content digest: how many entities carry it."
  @spec df(t(), String.t()) :: non_neg_integer()
  def df(index, hex) do
    MapSet.size(Map.get(index.by_feature, {:digest, hex}, MapSet.new()))
  end

  defp features(memory, set, sessions, cites) do
    sources =
      for delta_id <- memory.chain,
          {claims, _sig} <- [Map.get(set, delta_id)],
          %{role: "source", target: {:delta, source_id, _ctx}} <- claims.pointers,
          do: source_id

    MapSet.new(
      Enum.map(sources, &{:target, &1}) ++
        for(
          source_id <- sources,
          {:ok, session_id} <- [Map.fetch(sessions, source_id)],
          do: {:session, session_id}
        ) ++
        Enum.map(Map.get(cites, memory.entity, []), &{:cite, &1}) ++
        Enum.map(Assoc.digests(memory.content), &{:digest, &1})
    )
  end

  defp session_in(claims, id, sessions) do
    claims.pointers
    |> Enum.find_value(fn
      %{role: role, target: {:entity, session_id, _ctx}} when role in ["session", "sessionId"] ->
        session_id

      _pointer ->
        nil
    end)
    |> case do
      nil -> sessions
      session_id -> Map.put(sessions, id, session_id)
    end
  end

  defp cites_in(claims, id, head_owner, cites) do
    Enum.reduce(claims.pointers, cites, fn
      %{role: role, target: {:delta, target, _ctx}}, acc
      when role in ["memoryPointers", "memoryUsed"] ->
        case Map.fetch(head_owner, target) do
          {:ok, entity} -> Map.update(acc, entity, [id], &[id | &1])
          :error -> acc
        end

      _pointer, acc ->
        acc
    end)
  end
end
