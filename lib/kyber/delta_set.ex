defmodule Kyber.DeltaSet do
  @moduledoc """
  The grow-only delta set (spec/04-persistence.md §1–§2): a map of content id
  hex → full signed delta `{claims, sig_hex}`, so replay can re-verify. Merge
  is union — commutative, associative, idempotent. Two instances that meet
  merge; a lagging copy is merely behind, never wrong.
  """

  alias Rhizomatic.Delta

  @type element :: {Delta.claims(), String.t()}
  @type t :: %{optional(String.t()) => element()}

  @doc "An empty delta set."
  @spec new() :: t()
  def new, do: %{}

  @doc "Union: merge the sets by content id. Duplicates collapse; nothing is lost."
  @spec merge(t(), t()) :: t()
  def merge(a, b), do: Map.merge(a, b)

  @doc "Is the delta with this id hex in the set?"
  @spec member?(t(), String.t()) :: boolean()
  def member?(set, id_hex), do: Map.has_key?(set, id_hex)

  @doc "Number of deltas in the set."
  @spec size(t()) :: non_neg_integer()
  def size(set), do: map_size(set)
end
