defmodule Kyber.Agent.Memory.Assoc.Saturation do
  @moduledoc """
  The groove mechanism (T13): the retriever pre-fetches the association set
  for the current WINDOW into the next request — the lens becomes a
  resonance field, and recall cost falls toward zero as the session
  deepens. A pure function of (store, window): byte-identical re-fire
  holds, and because seeds derive ONLY from the bounded window, the walked
  edge count is flat after saturation.

  The window is `ContextBuilder.window/2` — the exact T11b split the
  engine's lens applies (one N, one split) — over the turns strictly below
  the prompt (the conversation_ref discipline: a crash window's leftover
  answer above the prompt never shifts the re-fire).
  """

  alias Kyber.Agent.ContextBuilder
  alias Kyber.Agent.Memory.Assoc
  alias Kyber.Agent.Memory.Assoc.Index
  alias Kyber.DeltaSet

  @type prefetch :: %{
          seeds: [String.t()],
          resonant: [String.t()],
          divergent: [String.t()],
          edges_walked: non_neg_integer()
        }

  @doc """
  Pre-fetch the association set for the session's current window: build the
  index, seed from the window ∪ prompt digests, walk, and map entity ids to
  canon HEAD ids (provenance rides the canon render — the T11c
  provenance-as-authority rule). Options: `:divergent_cap`.
  """
  @spec prefetch(DeltaSet.t(), String.t(), String.t(), keyword()) :: prefetch()
  def prefetch(set, session_id, prompt, opts \\ []) do
    index = Index.build(set)

    window_contents =
      set
      |> ContextBuilder.conversation(session_id)
      |> below_prompt(prompt)
      |> ContextBuilder.window()
      |> elem(1)
      |> Enum.map(& &1.content)

    seeds = Assoc.seeds(index, %{session_id: session_id, prompt: prompt}, window_contents)

    query_digests =
      (Assoc.digests(prompt) ++ Enum.flat_map(window_contents, &Assoc.digests/1))
      |> Enum.uniq()
      |> Enum.sort()

    walked = Assoc.walk(index, seeds, query_digests, Keyword.put(opts, :session_id, session_id))

    head = fn entity -> Map.fetch!(index.canons, entity).head end

    %{
      seeds: Enum.map(seeds, head),
      resonant: Enum.map(walked.resonant, head),
      divergent: Enum.map(walked.divergent, head),
      edges_walked: walked.edges_walked
    }
  end

  # turns strictly below the prompt: the prompt delta is already in the set
  # when the retriever fires, so the walk grounds on the conversation BELOW
  # it — a not-yet-persisted prompt (or a direct test call) sees every turn
  defp below_prompt(turns, prompt) do
    case Enum.find_index(turns, &(&1.role == "user" and &1.content == prompt)) do
      nil -> turns
      index -> Enum.take(turns, index)
    end
  end
end
