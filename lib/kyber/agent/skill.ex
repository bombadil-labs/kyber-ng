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
  (deterministic, terminates). The recursive-existential machinery is the
  SHARED `Kyber.Agent.Liveness` helper (T14g M1 — ONE implementation; skill
  passes the identity negator filter, identity passes the boot-constant
  author filter). The flat house `negates` scan (policy.ex / engine.ex /
  reactor.ex / attestation.ex) is deliberately NOT copied — it cannot
  express restore.
  """

  alias Kyber.{DeltaSet, Schema}
  alias Kyber.Agent.Liveness

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

        if live?(set, head_id) do
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

  # T14g M1: the SHARED recursive-existential liveness helper — skill passes
  # identity as the negator filter (author-blind, unchanged); identity
  # passes the boot-constant author filter (H2). ONE implementation, never
  # two divergent ones.
  defp live?(set, id), do: Liveness.live?(set, id, fn _claims -> true end)

  defp names(set) do
    (for {_id, {claims, _sig}} <- set,
         %{type: "SkillSet", skill: {:entity, name, _ctx}} <- [Schema.resolve(claims)],
         do: name)
    |> Enum.uniq()
  end
end
