defmodule Kyber.Agent.Identity do
  @moduledoc """
  The identity aggregate (T14g): the soul/user/operator primitives are
  DERIVED ENTITIES — a view over their `IdentitySet` delta stream, never a
  delta and never a stored blob. The fold is AUTHOR-FILTERED FIRST (H2):
  the stream is pre-filtered to the boot-constant `operator_author`'s
  claims BEFORE `{ts, id}` ordering — an agent's newer inert write can
  never SHADOW the operator's live soul (ordering DoS closed) — and the
  negations are author-filtered too (an agent cannot retract the soul
  out-of-band). The kind set is CLOSED and ordered: soul, user, operator.

  Liveness is the SKILL fold's liveness, VERBATIM (T14f H2/H3, via the
  shared `Kyber.Agent.Liveness` helper — M1): order-head,
  recursive-existential through the whole negation chain, restore = negate
  every live negation of the head, removal NEVER re-exposes the prior set,
  recomputed per read, never latched. The probe-2 truth table stays the
  liveness oracle (B dead / C live / D dead / E live / F dead). Two live
  same-kind heads resolve by explicit latest-wins on `{ts, id}` (the
  content-derived head) — never a fork error (G2).

  The always-on block (`block/3`) renders the primitives in CLOSED-SET
  order — `"Soul: "` / `"User: "` / `"Operator: "` note spellings (H5),
  then the `"Profile: <name>\n"` rules segment — capped at 8192 TOTAL
  rendered bytes, skip-and-continue per primitive (a primitive that would
  blow the bound is omitted ENTIRELY, never truncated), NEVER windowed. An
  unknown kind string or a whitespace-only kind/id is FOLD-INERT (closed
  set, reject-never-repair; N3).
  """

  alias Kyber.{DeltaSet, Schema}
  alias Kyber.Agent.Liveness

  # the closed, ordered kind set — the block renders in THIS order, never
  # `{ts, id}` of heads
  @kinds ["soul", "user", "operator"]

  # G3: the identity block's TOTAL rendered-byte cap — DISJOINT from the
  # skill lens's 8192 (two budgets, never pooled); the accounting unit is
  # the RENDERED NOTE BYTES (the prompt.ex:177 discipline)
  @block_cap 8192

  @type primitive :: %{
          kind: String.t(),
          entity: String.t(),
          body: String.t(),
          head: String.t()
        }

  @doc "The closed, ordered kind set."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The fold of one primitive: the LIVE order-head `IdentitySet` of `kind`
  over the boot-constant author's stream. `{:ok, primitive}` when the head
  is live; `:not_found` when the author has no `kind` claims OR the head is
  retracted (retracted ≡ never-existed at this surface — the stream keeps
  the distinction for audit). Pure, deterministic, no wall-clock.
  """
  @spec primitive(DeltaSet.t(), String.t(), String.t()) :: {:ok, primitive()} | :not_found
  def primitive(set, operator_author, kind) when kind in @kinds and is_binary(operator_author) do
    ordered =
      (for {id, {claims, _sig}} <- set,
           claims.author == operator_author,
           %{type: "IdentitySet", entity: {:entity, entity_id, _}, kind: ^kind, body: body} <-
             [Schema.resolve(claims)],
           not whitespace?(entity_id),
           do: {id, entity_id, body, claims.timestamp})
      |> Enum.sort_by(fn {id, _entity, _body, ts} -> {ts, id} end)

    case ordered do
      [] ->
        :not_found

      _ ->
        {head_id, entity_id, body, _ts} = List.last(ordered)

        if Liveness.live?(set, head_id, author_filter(operator_author)) do
          {:ok, %{kind: kind, entity: entity_id, body: body, head: head_id}}
        else
          :not_found
        end
    end
  end

  @doc """
  The always-on identity block: the LIVE primitives in CLOSED-SET order
  (soul, user, operator), then the `"Profile: <name>\n" <> rules` segment
  (when a profile view is bound), capped at 8192 TOTAL rendered bytes with
  skip-and-continue per note. `profile_view` is `nil` (profile-less boot:
  every live primitive rides) or a resolved `Kyber.Agent.Profile` view (the
  profile's `rides` identity refs select the riding primitives — the
  identity-view binding). The nil-seed leg (`operator_author == nil`) is
  FAIL-CLOSED: `[]`, never a crash.
  """
  @spec block(DeltaSet.t(), String.t() | nil, map() | nil) :: [String.t()]
  def block(_set, nil, _profile_view), do: []

  def block(set, operator_author, profile_view) when is_binary(operator_author) do
    notes =
      for kind <- @kinds,
          {:ok, primitive} <- [primitive(set, operator_author, kind)],
          rides?(profile_view, primitive.entity) do
        note(kind, primitive.body)
      end

    notes = notes ++ profile_segment(profile_view)
    cap(notes, 0, [])
  end

  @doc "Every LIVE primitive of the boot-constant author, keyed by kind — the fold's input to the block."
  @spec primitives(DeltaSet.t(), String.t()) :: %{optional(String.t()) => primitive()}
  def primitives(set, operator_author) when is_binary(operator_author) do
    Map.new(@kinds, fn kind ->
      case primitive(set, operator_author, kind) do
        {:ok, p} -> {kind, p}
        :not_found -> {kind, nil}
      end
    end)
    |> Enum.reject(fn {_kind, p} -> is_nil(p) end)
    |> Map.new()
  end

  # the H2 author filter: identity folds (primitives AND negations) pre-
  # filter the stream to the boot-constant author before {ts, id} ordering
  defp author_filter(operator_author), do: fn claims -> claims.author == operator_author end

  # profile-less boots ride every live primitive; under a profile the
  # identity view is the profile's `rides` identity refs (an empty rides
  # list rides nothing — fail-closed)
  defp rides?(nil, _entity), do: true
  defp rides?(%{rides: rides}, entity), do: entity in rides

  defp profile_segment(nil), do: []

  defp profile_segment(%{name: name, rules: rules}) do
    ["Profile: " <> name <> "\n" <> rules]
  end

  defp note(kind, body), do: note_label(kind) <> body

  defp note_label("soul"), do: "Soul: "
  defp note_label("user"), do: "User: "
  defp note_label("operator"), do: "Operator: "

  # G3: SKIP-AND-CONTINUE — a note that would blow the 8192 cap is omitted
  # ENTIRELY (never truncated), and later (smaller) notes may still fit;
  # stop-at-first-overflow rejected. The accounting unit is the RENDERED
  # note bytes.
  defp cap([], _bytes, acc), do: Enum.reverse(acc)

  defp cap([note | rest], bytes, acc) do
    note_bytes = byte_size(note)

    if bytes + note_bytes <= @block_cap do
      cap(rest, bytes + note_bytes, [note | acc])
    else
      cap(rest, bytes, acc)
    end
  end

  # N3: a whitespace-only id is FOLD-INERT — never repaired, never
  # normalized (reject-never-repair; inertness lives in the fold)
  defp whitespace?(id), do: String.trim(id) == ""
end
