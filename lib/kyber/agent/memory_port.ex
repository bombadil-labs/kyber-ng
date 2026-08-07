defmodule Kyber.Agent.MemoryPort do
  @moduledoc """
  The retriever seam (T11b): the context builder asks for memories through
  this behaviour and receives DELTA IDS — pointers into the store, never
  memory text — so the `InferenceRequested` delta it emits stays thin
  (composites point; the engine rehydrates content by pointer-walk).

  A real memory container behind this interface is T11c's job. This slice
  ships the seam plus a stub, and the A/B property (AC10) is exactly that
  the two are interchangeable at construction: `{module, state}`, same shape
  as the HTTP seam.
  """

  @type query :: %{session_id: String.t(), prompt: String.t()}

  @doc """
  Retrieve the memory deltas relevant to a prompt: delta ids into the store,
  most relevant first. The retriever never answers content — content lives
  in the store and rides the pointer-walk.
  """
  @callback retrieve(query(), state :: term()) :: {:ok, [String.t()]} | {:error, term()}

  defmodule Stub do
    @moduledoc """
    The slice's stand-in retriever: answers the delta ids configured in its
    state (`%{memories: [id]}`), or none. Deterministic — a byte-identical
    `InferenceRequested` re-fire (AC3) depends on retrieval being a function
    of the store, not of the moment.
    """
    @behaviour Kyber.Agent.MemoryPort

    @impl true
    def retrieve(_query, state), do: {:ok, Map.get(state || %{}, :memories, [])}
  end
end
