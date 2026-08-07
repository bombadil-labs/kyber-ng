defmodule Kyber.Agent.Memory.Retriever do
  @moduledoc """
  The REAL `Kyber.Agent.MemoryPort` implementation (T11c): answers delta ids
  into the store — the canon head of each resolved memory, provenance-ranked
  (human above auto, `Kyber.Agent.Memory.Tierer`) — never memory text
  (composites point; content rides the pointer-walk).

  The carried determinism clause binds by construction: `retrieve/2` is a
  pure function of (store, query, state) — the store rides IN the state
  (`%{store: set | fun}`, the same shape the context builder threads), and
  resolution + ranking are pure store reads. No wall-clock, no services, no
  mutable state — a byte-identical `InferenceRequested` re-fire (AC3)
  depends on it.

  The A/B property (AC10): this module and `Kyber.Agent.MemoryPort.Stub`
  are interchangeable at construction — `{module, state}` behind the same
  seam, against the same store.
  """

  @behaviour Kyber.Agent.MemoryPort

  alias Kyber.Agent.Memory
  alias Kyber.Agent.Memory.Assoc.Saturation
  alias Kyber.Agent.Memory.Tierer
  alias Kyber.DeltaSet

  # The T13 associative mode (mode flag, never a second pipeline): state
  # `%{store: s, assoc: true}` answers the UNCHANGED T11c precision list
  # plus the bounded association channels — canon-HEAD ids, bare. The
  # divergent channel is capped (`:divergent_cap` state key overrides the
  # boot default) so it can never drown precision recall. Without the flag
  # the answer is byte-identical T11c.
  @impl true
  def retrieve(
        %{session_id: session_id, prompt: prompt} = query,
        %{store: store, assoc: true} = state
      ) do
    set = materialize(store)
    {:ok, memory_ids} = retrieve(query, Map.delete(state, :assoc))

    prefetch = Saturation.prefetch(set, session_id, prompt, prefetch_opts(state))

    {:ok,
     %{
       memory_ids: memory_ids,
       associations: Map.take(prefetch, [:seeds, :resonant, :divergent])
     }}
  end

  def retrieve(_query, %{store: store} = state) do
    {:ok,
     store
     |> materialize()
     |> Memory.resolve_set(Map.get(state, :human_author))
     |> Tierer.rank()
     |> Enum.map(& &1.head)}
  end

  def retrieve(_query, _state), do: {:error, :no_store}

  @doc """
  Trajectory retrieval: the time-ordered chain of a memory's resolutions,
  oldest → newest, as delta ids — a pure store read.
  """
  @spec trajectory(DeltaSet.t(), String.t()) :: [String.t()]
  def trajectory(set, entity_id), do: Memory.trajectory(set, entity_id)

  defp prefetch_opts(%{divergent_cap: cap}), do: [divergent_cap: cap]
  defp prefetch_opts(_state), do: []

  defp materialize(store) when is_function(store, 0), do: store.()
  defp materialize(store), do: store
end
