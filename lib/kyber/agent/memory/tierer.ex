defmodule Kyber.Agent.Memory.Tierer do
  @moduledoc """
  Provenance weighting (T11c): human-edited memory ranks above auto-derived.
  A pure function of resolved memories — no clocks, no services — so the
  retriever built on it stays a pure function of the store (the carried
  MemoryPort determinism clause).

  Within a tier, newer canon ranks first; entity id breaks the last tie so
  the order is total and replay-stable.
  """

  alias Kyber.Agent.Memory

  @tiers %{human: 0, auto: 1}

  @doc "Rank resolved memories: human tier first, then canon recency, then entity id."
  @spec rank([Memory.memory()]) :: [Memory.memory()]
  def rank(memories) do
    Enum.sort_by(memories, &{tier(&1.provenance), -&1.timestamp, &1.entity})
  end

  @doc "The numeric tier for a provenance — lower ranks first."
  @spec tier(:human | :auto) :: non_neg_integer()
  def tier(provenance), do: Map.fetch!(@tiers, provenance)
end
