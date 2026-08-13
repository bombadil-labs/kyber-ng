defmodule Kyber.Agent.Liveness do
  @moduledoc """
  The SHARED recursive-existential liveness helper (T14g M1 — ONE
  implementation, never two divergent ones): a delta id is LIVE iff NO live
  negation targets it, through the WHOLE negation chain, recomputed per
  read, never latched (T14f D4/H3 — the probe-2 oracle: B dead / C live /
  D dead / E live / F dead; flat scans kill restore and are deliberately
  NOT copied). Restore = negate every live negation of the head.

  Parameterized by a NEGATOR FILTER: identity passes the boot-constant
  author filter (T14g H2 — an agent cannot retract the soul out-of-band),
  skill passes identity (author-blind, unchanged).
  """

  @doc """
  Live iff no LIVE negation (passing `filter`) targets `id`. `filter` is a
  fun from claims to boolean — identity passes `fn claims -> claims.author
  == operator_author end` (H2); skill passes identity (author-blind).
  """
  @spec live?(map(), String.t(), (map() -> boolean())) :: boolean()
  def live?(set, id, filter) do
    live?(set, id, filter, MapSet.new())
  end

  # the path-guard copied VERBATIM from skill.ex:105-117 (L3 — cycles are
  # unconstructible with content-derived ids, so the guard is belt-and-
  # suspenders, but copy it anyway): a revisited id answers live, so a
  # negation cycle is self-neutralizing and the fold terminates
  # iteration-order-independently.
  defp live?(set, id, filter, path) do
    if MapSet.member?(path, id) do
      true
    else
      path = MapSet.put(path, id)
      # live iff NO LIVE negation targets it: not (exists y in N(x): live(y))
      not Enum.any?(negators(set, id, filter), fn negator -> live?(set, negator, filter, path) end)
    end
  end

  @doc """
  The negation scan — kind-agnostic (any claim with a `negates` pointer is
  the house retraction vocabulary), FILTERED by `filter` (H2: identity
  admits only the boot-constant author's negations; skill admits all).
  """
  @spec negators(map(), String.t(), (map() -> boolean())) :: [String.t()]
  def negators(set, id, filter) do
    for {nid, {claims, _sig}} <- set,
        filter.(claims),
        %{role: "negates", target: {:delta, ^id, _ctx}} <- claims.pointers,
        do: nid
  end
end
