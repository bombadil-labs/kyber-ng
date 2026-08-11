defmodule Kyber.Agent.Standing do
  @moduledoc """
  The always-on FOLDS (T14h H1/H4/H6): standing memory and open threads are
  READ-TIME folds, recomputed per assembly — fresh every prompt, never
  latched.

  Standing (A1, fold-based): a memory entity rides the standing section iff
  ≥1 LIVE `StandingFlag` ∧ a LIVE canon head ∧ the governing memory epoch
  allows it (H4 — visibility ≠ salience: an epoch may allow hundreds of
  entities for retrieval without all of them riding every prompt). The
  section is born FAIL-CLOSED (H6 — the T14f D6 doctrine): it renders only
  under `{:ok, epoch}` from the governing memory family; `:none` and
  `{:error, :forked}` render nothing, profile or not. Under a profile the
  epoch is the profile's UNION (`Profile.memory_epoch/2` — the G8 derived
  fail-closed defaults govern nothing when the profile names no family).
  Liveness is the SHARED `Kyber.Agent.Liveness` oracle, AUTHOR-BLIND (M6 —
  the skill.ex:109 posture) for the flag AND the canon head:
  `Memory.resolve_set` is retraction-blind by its own slice's design
  (memory.ex:98-129), so the fold applies head-liveness itself — a
  retracted flagged entity is absent from every prompt. Lines render in
  `{ts, id}` ASCENDING order (M7 — the AC5 norm; `resolve_set`'s
  entity-id sort is NOT the norm). Whitespace-only flagged entity ids are
  fold-inert (never repaired).

  Open threads (A3, a SEPARATE per-assembly fold — never in-digest): the
  session's unanswered `InferenceRequested` chains (the resume-scan class,
  M2), `{ts, id}` ASCENDING. The fold consumes the SHARED
  `ContextBuilder.answered?/2` + `ContextBuilder.chain_position/2` helpers
  (M2 — ONE implementation, never a re-implementation); a `:tool_waiting`
  chain renders with the "(tool waiting)" suffix — in-flight tool chains
  are surfaced, never missed.
  """

  alias Kyber.{DeltaSet, Schema}
  alias Kyber.Agent.{ContextBuilder, Liveness, Memory, Policy, Profile}

  # M6: the liveness filter is AUTHOR-BLIND at all four new call-sites (the
  # skill.ex:109 posture — the runbook's operator hand-rolled negations must
  # count)
  defp author_blind(_claims), do: true

  @doc """
  The standing fold: the memory entities that are live-flagged ∧
  head-live-canon ∧ epoch-allowed, `{ts, id}` ASCENDING (M7 — the canon
  head's `{timestamp, head-id}`). `profile_view` is `nil` (profile-less
  boot: the broad memory-family epoch governs) or a resolved
  `Kyber.Agent.Profile` view (the profile's UNION governs — H6). `[]` under
  `:none`/`:forked` (fail-closed) or when nothing qualifies.
  """
  @spec fold(DeltaSet.t(), map() | nil) :: [%{
          entity: String.t(),
          content: String.t(),
          timestamp: float(),
          head: String.t()
        }]
  def fold(set, profile_view) do
    case epoch(set, profile_view) do
      {:ok, epoch} ->
        memories = Memory.resolve_set(set)

        set
        |> flags()
        |> Enum.uniq()
        |> Enum.flat_map(fn entity_id ->
          case Enum.find(memories, &(&1.entity == entity_id)) do
            %{content: content, head: head, timestamp: ts} ->
              if Liveness.live?(set, head, &author_blind/1) and
                   Policy.check_memory(epoch, entity_id) == :allow do
                [%{entity: entity_id, content: content, timestamp: ts, head: head}]
              else
                []
              end

            nil ->
              []
          end
        end)
        |> Enum.sort_by(&{&1.timestamp, &1.head})

      _none_or_forked ->
        []
    end
  end

  @doc """
  The open-threads fold: the session's unanswered `InferenceRequested`
  chains, `{ts, id}` ASCENDING (M1 — contiguous-stop over the pinned
  order; never skip-whole: a hole in a thread list lies about open work).
  Each thread carries its asked prompt content and whether the chain is
  `:tool_waiting` (an in-flight tool call).
  """
  @spec open(DeltaSet.t(), String.t()) :: [
          %{id: String.t(), timestamp: float(), content: String.t(), waiting: boolean()}
        ]
  def open(set, session_id) do
    (for {id, {claims, _sig}} <- set,
         kind(claims) == "promptRef",
         %{type: "InferenceRequested"} = typed <- [Schema.resolve(claims)],
         match?({:entity, ^session_id, _ctx}, typed.sessionId),
         not ContextBuilder.answered?(set, id),
         do: thread(set, id, typed))
    |> Enum.sort_by(&{&1.timestamp, &1.id})
  end

  # the standing epoch source: under a profile the UNION (always {:ok, _} —
  # an unseeded union governs nothing); profile-less the broad memory-family
  # epoch (:none / {:error, :forked} render nothing — born fail-closed)
  defp epoch(set, nil), do: Policy.memory_epoch(set)
  defp epoch(set, %{name: _name} = view), do: Profile.memory_epoch(set, view)

  # the LIVE StandingFlag entities (the "standing" kind marker routes to no
  # subscription; the negator scan is author-blind — M6)
  defp flags(set) do
    for {id, {claims, _sig}} <- set,
        kind(claims) == "standing",
        %{type: "StandingFlag", standing: {:entity, entity_id, _ctx}} <-
          [Schema.resolve(claims)],
        not whitespace?(entity_id),
        Liveness.live?(set, id, &author_blind/1),
        do: entity_id
  end

  defp thread(set, id, typed) do
    %{
      id: id,
      timestamp: typed.timestamp,
      content: asked_content(set, typed.promptRef),
      waiting: ContextBuilder.chain_position(set, id) == :tool_waiting
    }
  end

  defp asked_content(set, {:delta, prompt_id, _ctx}) do
    case Map.get(set, prompt_id) do
      {claims, _sig} ->
        case pointer(claims, "content") do
          {:string, content} -> content
          _other -> ""
        end

      nil ->
        ""
    end
  end

  defp asked_content(_set, _other), do: ""

  # N3: whitespace-only flagged entity ids are fold-inert — never repaired
  # (reject-never-repair; inertness lives in the fold)
  defp whitespace?(id), do: String.trim(id) == ""

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
