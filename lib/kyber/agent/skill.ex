defmodule Kyber.Agent.Skill do
  @moduledoc """
  The skill aggregate (T14f): events + fold — a skill is a DERIVED entity, a
  VIEW over its delta stream, never a delta and never a stored blob. Each
  `SkillSet` delta writes the WHOLE property set (name — the aggregate key —
  description, body, optional metadata JSON, optional source pointer);
  supersede is WHOLE-SET across deltas (H6): an absent optional role is
  CLEARED, and per-property language applies only within one full-set delta.

  The fold (`view/2`) is a pure function of a `DeltaSet`: it gathers the
  name's set-deltas, orders them by `{claims.timestamp, id}` (D2 — the only
  content-derived total order in the substrate: total, fork-safe,
  replica-identical; never "append order", which no resolution site can
  observe), derives `version` as the count of ALL the name's set-deltas (D3,
  L6 — retraction-immune: remove/restore never renumbers, re-creation
  continues the count), and answers the latest LIVE set under the head.

  Liveness is RECURSIVE-EXISTENTIAL (D4/H3 — the probe-2 oracle): a skill is
  not-found iff its order-head set-delta is retracted, where a delta is
  retracted iff some LIVE negation targets it, and a negation is live iff it
  is not itself negated — through the WHOLE negation chain, recomputed per
  read, never latched. Restore = negate every live negation of the head; a
  retraction of a non-head set-delta is a silent no-op; removal of the head
  NEVER exposes the prior version (no retraction-path rollback — rollback is
  a NEW superseding set, forward-only). A negation cycle is self-neutralizing
  (deterministic, terminates). The flat house `negates` scan (policy.ex /
  engine.ex / reactor.ex / attestation.ex) is deliberately NOT copied — it
  cannot express restore.
  """

  alias Kyber.{DeltaSet, Schema}

  @type view :: %{
          name: String.t(),
          description: String.t(),
          body: String.t(),
          metadata: String.t() | nil,
          source: {:delta, String.t(), String.t()} | nil,
          version: non_neg_integer(),
          head: String.t(),
          timestamp: float()
        }

  @doc """
  The fold: the current view of the skill named `name` over `set`. `{:ok,
  view}` when the order-head set-delta is live; `:not_found` when the name
  has no set-deltas OR its head is retracted (retracted ≡ never-existed at
  this surface — the stream keeps the distinction for audit). Pure,
  deterministic, no wall-clock.
  """
  @spec view(DeltaSet.t(), String.t()) :: {:ok, view()} | :not_found
  def view(set, name) when is_binary(name) do
    ordered =
      (for {id, {claims, _sig}} <- set,
           %{type: "SkillSet", skill: {:entity, ^name, _ctx}} = typed <- [Schema.resolve(claims)],
           do: {id, typed})
      |> Enum.sort_by(fn {id, typed} -> {typed.timestamp, id} end)

    case ordered do
      [] ->
        :not_found

      _ ->
        {head_id, head} = List.last(ordered)

        if live?(set, head_id, MapSet.new()) do
          {:ok,
           %{
             name: name,
             description: head.description,
             body: head.body,
             metadata: head.metadata,
             source: head.source,
             version: length(ordered),
             head: head_id,
             timestamp: head.timestamp
           }}
        else
          :not_found
        end
    end
  end

  @doc """
  Every LIVE skill view in `set`, sorted by name — the lens's fold input
  (the lens matches over views, never the raw streams). Deterministic.
  """
  @spec views(DeltaSet.t()) :: [view()]
  def views(set) do
    set
    |> names()
    |> Enum.flat_map(fn name ->
      case view(set, name) do
        {:ok, v} -> [v]
        :not_found -> []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  # recursive-existential liveness: a delta id is live iff NO live negation
  # targets it. `path` guards the recursion — a negation cycle is
  # self-neutralizing (a revisited id answers live), so the fold terminates
  # and stays iteration-order-independent (the existential is order-free).
  defp live?(set, id, path) do
    if MapSet.member?(path, id) do
      true
    else
      path = MapSet.put(path, id)
      # live iff NO LIVE negation targets it: not (exists y in N(x): live(y))
      not Enum.any?(negators(set, id), fn negator -> live?(set, negator, path) end)
    end
  end

  # the negation scan is kind-agnostic (any claim with a `negates` pointer),
  # the house retraction vocabulary — out-of-band negations take effect on
  # their target's arrival (L5), and the SkillRetract kind rides the same
  # role.
  defp negators(set, id) do
    for {nid, {claims, _sig}} <- set,
        %{role: "negates", target: {:delta, ^id, _ctx}} <- claims.pointers,
        do: nid
  end

  defp names(set) do
    (for {_id, {claims, _sig}} <- set,
         %{type: "SkillSet", skill: {:entity, name, _ctx}} <- [Schema.resolve(claims)],
         do: name)
    |> Enum.uniq()
  end
end
