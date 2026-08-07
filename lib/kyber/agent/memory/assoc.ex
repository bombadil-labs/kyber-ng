defmodule Kyber.Agent.Memory.Assoc do
  @moduledoc """
  The pure walk (T13): from a seed set of resolved entities, follow pointer
  edges (shared targets, shared sessions, shared cites, shared
  content-digest hashes) up to bounded depth, collecting neighbors —
  `{resonant, divergent}`. Resonant = neighbors with a direct edge to a seed
  (relevance); divergent = the capped anomaly channel (rare shared-feature
  overlap, NO direct link — synchronicity as a graph property).

  Pure structural association ONLY: every edge is a deterministic store
  read; no embedding service, no wall-clock (the T11b determinism clause —
  an embedding-backed semantic layer stays a documented boot-boundary
  swap). Association is a policy, never a truth-maker: the walk returns
  REAL entity ids, never fabricates.

  Direct link is QUERY-RELATIVE: e↔s is direct iff they share a
  `{:target, _}` or `{:cite, _}` feature, or both carry
  `{:session, query_session}`. A shared NON-query session is NOT direct —
  that is the synchronicity.
  """

  alias Kyber.Agent.Memory.Assoc.Index
  alias Kyber.Agent.Memory.Tierer

  @max_seeds 4
  @max_depth 2
  @max_candidates 32
  @max_resonant 8
  @divergent_cap 2
  # the ceiling on any boot override of :divergent_cap (post-premortem
  # hardening): the tail invariant (≤ 4+8+cap, precision never drowned)
  # holds only if the override is bounded — this clamps it
  @max_divergent_cap 8
  @min_shared 2
  # fixed constant, never N-dependent — re-fire-stable as the store grows
  @max_df 2

  @type walk_result :: %{
          resonant: [String.t()],
          divergent: [String.t()],
          edges_walked: non_neg_integer()
        }

  @doc """
  Tokenize content into sorted SHA-256 digests: lowercase, alphanumeric
  split, tokens ≥ 4 bytes (the floor kills stopwords without a list),
  deduplicated, hashed, sorted.
  """
  @spec digests(String.t()) :: [String.t()]
  def digests(content) do
    content
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.filter(&(byte_size(&1) >= 4))
    |> Enum.uniq()
    |> Enum.map(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
    |> Enum.sort()
  end

  @doc """
  The query's seed entities: entities carrying `{:session, session_id}`
  sharing ≥ 1 digest with digests(prompt) ∪ digests(window_contents),
  ranked by `{-shared_digest_count, tier, -timestamp, entity_id}`, top
  #{@max_seeds}. Empty seeds ⇒ empty channels.
  """
  @spec seeds(Index.t(), %{session_id: String.t(), prompt: String.t()}, [String.t()]) ::
          [String.t()]
  def seeds(index, %{session_id: session_id, prompt: prompt}, window_contents) do
    query = MapSet.new(digests(prompt) ++ Enum.flat_map(window_contents, &digests/1))

    index.by_entity
    |> Enum.filter(fn {_entity, features} -> MapSet.member?(features, {:session, session_id}) end)
    |> Enum.map(fn {entity, features} -> {entity, shared_count(features, query)} end)
    |> Enum.filter(fn {_entity, shared} -> shared >= 1 end)
    |> Enum.sort_by(fn {entity, shared} ->
      canon = Map.fetch!(index.canons, entity)
      {-shared, Tierer.tier(canon.provenance), -canon.timestamp, entity}
    end)
    |> Enum.take(@max_seeds)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The instrumented BFS: depth ≤ #{@max_depth}; per depth the frontier's
  features are expanded (`edges_walked` counts every neighbor-set size) and
  the next frontier is the top #{@max_candidates} by the sort tuple
  `{-structural_edges, -shared_digests, tier, -timestamp, entity_id}`.
  Options: `:session_id` (the query session, for the direct-link rule),
  `:divergent_cap` (boot override of #{@divergent_cap}).
  """
  @spec walk(Index.t(), [String.t()], [String.t()], keyword()) :: walk_result()
  def walk(index, seeds, query_digests, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)

    divergent_cap =
      opts
      |> Keyword.get(:divergent_cap, @divergent_cap)
      |> min(@max_divergent_cap)

    pool = MapSet.new(query_digests ++ Enum.flat_map(seeds, &entity_digests(index, &1)))
    structural = fn entity -> Enum.count(seeds, &direct?(index, entity, &1, session_id)) end
    shared = fn entity -> Enum.count(entity_digests(index, entity), &MapSet.member?(pool, &1)) end

    rank = fn entity ->
      canon = Map.fetch!(index.canons, entity)

      {-structural.(entity), -shared.(entity), Tierer.tier(canon.provenance), -canon.timestamp,
       entity}
    end

    {candidates, edges_walked} = collect(index, seeds, rank)

    rare = fn entity ->
      index
      |> entity_digests(entity)
      |> Enum.count(&(MapSet.member?(pool, &1) and Index.df(index, &1) <= @max_df))
    end

    resonant =
      candidates
      |> Enum.filter(&(structural.(&1) >= 1))
      |> Enum.sort_by(rank)
      |> Enum.take(@max_resonant)

    divergent =
      candidates
      |> Enum.filter(&(structural.(&1) == 0 and rare.(&1) >= @min_shared))
      |> Enum.sort_by(fn entity ->
        canon = Map.fetch!(index.canons, entity)
        {-rare.(entity), Tierer.tier(canon.provenance), -canon.timestamp, entity}
      end)
      |> Enum.take(divergent_cap)

    %{resonant: resonant, divergent: divergent, edges_walked: edges_walked}
  end

  # ------------------------------------------------------------------ walk

  defp collect(index, seeds, rank) do
    {_frontier, _visited, candidates, edges} =
      Enum.reduce(1..@max_depth, {seeds, MapSet.new(seeds), [], 0}, fn
        _depth, {frontier, visited, candidates, edges} ->
          features =
            frontier
            |> Enum.map(&Map.get(index.by_entity, &1, MapSet.new()))
            |> Enum.reduce(MapSet.new(), &MapSet.union/2)

          {neighbors, edges} =
            Enum.reduce(features, {MapSet.new(), edges}, fn feature, {acc, edges} ->
              hits = Map.get(index.by_feature, feature, MapSet.new())
              {MapSet.union(acc, hits), edges + MapSet.size(hits)}
            end)

          fresh = MapSet.difference(neighbors, visited)
          next = fresh |> Enum.sort_by(rank) |> Enum.take(@max_candidates)

          {next, MapSet.union(visited, fresh), candidates ++ next, edges}
      end)

    {candidates, edges}
  end

  defp direct?(index, entity, seed, session_id) do
    entity_features = Map.get(index.by_entity, entity, MapSet.new())
    seed_features = Map.get(index.by_entity, seed, MapSet.new())
    shared = MapSet.intersection(entity_features, seed_features)

    Enum.any?(shared, &match?({:target, _}, &1)) or
      Enum.any?(shared, &match?({:cite, _}, &1)) or
      (is_binary(session_id) and MapSet.member?(shared, {:session, session_id}))
  end

  defp entity_digests(index, entity) do
    for {:digest, hex} <- Map.get(index.by_entity, entity, MapSet.new()), do: hex
  end

  defp shared_count(features, query) do
    Enum.count(features, fn
      {:digest, hex} -> MapSet.member?(query, hex)
      _feature -> false
    end)
  end
end
