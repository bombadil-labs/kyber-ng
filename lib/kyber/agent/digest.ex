defmodule Kyber.Agent.Digest do
  @moduledoc """
  The trajectory digest (T14h H2/H5/H7): a `StandingDigest` DELTA FAMILY —
  the historical view of the session's recent activity (the atom: the store
  only learns). The mint is a ZERO-CHARGE side emission on the engine's
  answer path, per answered turn: no `Budget.charge`, no turn attribution,
  no `GateDecision`. The covered kinds are {MessageReceived, ResponseDelta,
  ToolCall, ToolResult, GateDecision}, session-scoped at mint AND read,
  LIVENESS-FILTERED BEFORE line derivation through the shared
  `Kyber.Agent.Liveness` oracle (AUTHOR-BLIND — the skill.ex:109 posture):
  `ContextBuilder.conversation/2` is retraction-blind by its slice's
  design, and the pointer-join legs have no negation handling of their own
  — a negated source must not produce a line, for ALL five kinds (H2).

  Derivation (H1 — PRE-EMISSION): the mint derives over the set read at
  the triggering dispatch's ENTRY (engine.ex:197's binding read), NEVER a
  re-read at mint time — the just-emitted `ResponseDelta` (wall-clock ts)
  is NOT in it, so two sequential cold boots over identical wire logs mint
  IDENTICAL digest ids (AC5), sink-implementation-independent.

  The mint (H7): trigger-`claims.timestamp` (the answered request's ts,
  never wall-clock, never a tick); the change-guard compares the POST-CAP
  RENDERED content against the last MINTED head — live or dead — and mints
  only on content change; per-session ts monotonicity is the EXPECTATION
  (M5 — the head selection and the guard both assume it): a federated
  late-arriving old-ts request still mints (the guard compares content),
  its dark digest is harmless (never the head), merge-is-union handles it —
  recorded, never "fixed"; a content-identical re-mint collapses to the
  negated id under merge-is-union and stays dark (the remediation runbook's
  purge semantics); empty derivation mints nothing; construction errors
  SWALLOW (`_error -> :ok` — M9, the `maybe_summarize` posture; the PA
  mint's raise is NOT the precedent).

  The read: `head/2` — the max `{ts, id}` `StandingDigest` claim of the
  session, LIVE only, NO-ROLLBACK: a retracted digest head means the fold
  is `:none` until the next mint (T14f D4 / T14g G4 — the fallback-to-
  previous-head re-exposes the just-negated content). Two live same-session
  heads resolve latest-wins, never a fork error (T14g G2).

  N = 16 items (2×window — `@default_window 8`), selected newest-first by
  `{ts, id}`, rendered chronological; 2048-byte mint cap on the content
  role, CONTIGUOUS stop-at-overflow (never skip-whole — holes lie about
  the sequence). `covers` = the POST-CAP covered set (M8): EXACTLY the
  rendered lines' deltas — the audit role never overclaims.

  Line grammar (M4): "done" lines carry the tool NAME + the RESULT SUMMARY
  (the first 80 chars of the result text) — args NEVER ride; the exposure
  class is bounded (80 chars of result, zero args). asked/answered/called/
  decided lines complete the asked/done/decided view including mechanism
  events (GateDecision verdicts — the leg the raw window never shows).
  Newlines normalize to spaces (whole-line rendering).

  Digest-of-digest exclusion is structural: `StandingDigest`'s
  sessionId-first kind marker routes to no subscription and matches no
  lens — the minter never observes its own output.
  """

  alias Kyber.{DeltaSet, Schema, Wire}
  alias Kyber.Agent.{ContextBuilder, Events, Liveness}

  # H5: N = 16 items (2×window — the engine's @default_window 8); the mint
  # byte cap on the content role
  @max_items 16
  @mint_cap 2048

  # M6: author-blind liveness — the runbook's operator hand-rolled
  # negations must count
  defp author_blind(_claims), do: true

  @type item :: %{
          kind: :asked | :answered | :called | :done | :decided,
          id: String.t(),
          ts: float(),
          content: String.t() | nil,
          tool: String.t() | nil,
          result: String.t() | nil,
          verdict: String.t() | nil
        }

  # --------------------------------------------------------------- derivation

  @doc """
  The POST-CAP derivation over `set` for `session_id`: `%{content: String.t(),
  covers: [String.t()]}`. `content` is the rendered trajectory (newest-16
  items, contiguous 2048-byte stop, rendered chronological); `covers` lists
  EXACTLY the rendered lines' deltas (M8). Deterministic — a pure function
  of the set.
  """
  @spec derive(DeltaSet.t(), String.t()) :: %{content: String.t(), covers: [String.t()]}
  def derive(set, session_id) do
    items =
      set
      |> covered_items(session_id)
      |> Enum.sort_by(&{&1.ts, &1.id})
      |> Enum.reverse()
      |> Enum.take(@max_items)

    {kept, _bytes} =
      Enum.reduce_while(items, {[], 0}, fn item, {acc, bytes} ->
        line = line(item)
        new_bytes = if acc == [], do: byte_size(line), else: bytes + 1 + byte_size(line)

        if new_bytes <= @mint_cap do
          {:cont, {[item | acc], new_bytes}}
        else
          # contiguous stop-at-overflow: the OLDER items (later in the
          # newest-first walk) are dropped whole — never skip-and-continue
          {:halt, {acc, bytes}}
        end
      end)

    %{
      content: Enum.map_join(kept, "\n", &line/1),
      covers: Enum.map(kept, & &1.id)
    }
  end

  @doc """
  The digest head read (the trajectory section's source): the max `{ts, id}`
  `StandingDigest` claim of the session, `{:ok, content}` when LIVE —
  NO-ROLLBACK: a retracted head (or no head) is `:none` until the next mint.
  """
  @spec head(DeltaSet.t(), String.t()) :: {:ok, String.t()} | :none
  def head(set, session_id) do
    case digest_heads(set, session_id) do
      [] ->
        :none

      claims ->
        {id, claims} = Enum.sort_by(claims, fn {id, c} -> {c.timestamp, id} end) |> List.last()

        if Liveness.live?(set, id, &author_blind/1) do
          case pointer(claims, "content") do
            {:string, content} -> {:ok, content}
            _other -> :none
          end
        else
          :none
        end
    end
  end

  # ---------------------------------------------------------------- the mint

  @doc """
  The zero-charge mint (H7): derive over `set` (the triggering dispatch's
  ENTRY binding — never a re-read), compare POST-CAP content against the
  last MINTED head (live or dead), and emit one `StandingDigest` through
  `sink` when the content CHANGED (and is non-empty). `trigger_ts` is the
  triggering `InferenceRequested`'s `claims.timestamp` — never wall-clock.
  Construction errors SWALLOW (`_error -> :ok` — M9); the side emission is
  never a crash surface and never charges a budget.
  """
  @spec mint(String.t(), (map() -> term()), DeltaSet.t(), String.t(), number()) :: :ok
  def mint(seed, sink, set, session_id, trigger_ts) do
    %{content: content, covers: covers} = derive(set, session_id)

    if content == "" do
      # empty derivation => no mint; the enforcement point is the minter
      :ok
    else
      case last_minted(set, session_id) do
        %{content: ^content} ->
          # the change-guard: only a content CHANGE mints fresh; an
          # identical re-mint would collapse to the negated id and stay dark
          :ok

        _other ->
          case Events.standing_digest(seed, trigger_ts, session_id, content, covers) do
            {:ok, signed} ->
              sink.(Wire.envelope(signed))
              :ok

            _error ->
              # M9: the zero-charge side emission is never a crash surface
              # (the maybe_summarize posture — engine.ex:634)
              :ok
          end
      end
    end
  end

  # the last minted head — live OR dead (the change-guard's comparison
  # target: H7 — "the last MINTED head, live or dead")
  defp last_minted(set, session_id) do
    case digest_heads(set, session_id) do
      [] ->
        nil

      claims ->
        {_id, claims} =
          Enum.sort_by(claims, fn {id, c} -> {c.timestamp, id} end) |> List.last()

        content_map(claims)
    end
  end

  defp content_map(claims) do
    case pointer(claims, "content") do
      {:string, content} -> %{content: content}
      _other -> %{content: ""}
    end
  end

  # every StandingDigest claim of the session — live or dead (the guard and
  # the no-rollback read both scan the WHOLE stream)
  defp digest_heads(set, session_id) do
    for {id, {claims, _sig}} <- set,
        declared_type(claims) == "StandingDigest",
        match?({:entity, ^session_id, _ctx}, pointer(claims, "sessionId")),
        do: {id, claims}
  end

  # ------------------------------------------------------------ covered set

  # the covered items: the five kinds, session-scoped, liveness-filtered
  # BEFORE line derivation (H2 — conversation/2's output AND the
  # pointer-join legs alike)
  defp covered_items(set, session_id) do
    request_ids = session_request_ids(set, session_id)
    turns = ContextBuilder.conversation(set, session_id)

    asked =
      for %{id: id, role: "user", content: content, timestamp: ts} <- turns,
          Liveness.live?(set, id, &author_blind/1),
          do: %{kind: :asked, id: id, ts: ts, content: content}

    answered =
      for %{id: id, role: "assistant", content: content, timestamp: ts} <- turns,
          Liveness.live?(set, id, &author_blind/1),
          do: %{kind: :answered, id: id, ts: ts, content: content}

    called =
      for {id, {claims, _sig}} <- set,
          kind(claims) == "tool",
          Liveness.live?(set, id, &author_blind/1),
          %{type: "ToolCall", requestRef: {:delta, request_id, _}, tool: {:entity, tool_id, _}} <-
            [Schema.resolve(claims)],
          MapSet.member?(request_ids, request_id),
          do: %{kind: :called, id: id, ts: claims.timestamp, tool: tool_id}

    done =
      for {id, {claims, _sig}} <- set,
          kind(claims) == "call",
          Liveness.live?(set, id, &author_blind/1),
          %{type: "ToolResult", call: {:delta, call_id, _}, result: result} <-
            [Schema.resolve(claims)],
          %{type: "ToolCall", requestRef: {:delta, request_id, _}, tool: {:entity, tool_id, _}} <-
            [resolve_call(set, call_id)],
          MapSet.member?(request_ids, request_id),
          do: %{kind: :done, id: id, ts: claims.timestamp, tool: tool_id, result: result}

    decided =
      for {id, {claims, _sig}} <- set,
          kind(claims) == "decides",
          Liveness.live?(set, id, &author_blind/1),
          %{type: "GateDecision", decides: {:delta, call_id, _}, verdict: verdict} <-
            [Schema.resolve(claims)],
          %{type: "ToolCall", requestRef: {:delta, request_id, _}} <-
            [resolve_call(set, call_id)],
          MapSet.member?(request_ids, request_id),
          do: %{kind: :decided, id: id, ts: claims.timestamp, verdict: to_string(verdict)}

    asked ++ answered ++ called ++ done ++ decided
  end

  defp session_request_ids(set, session_id) do
    for {id, {claims, _sig}} <- set,
        kind(claims) == "promptRef",
        %{type: "InferenceRequested", sessionId: {:entity, ^session_id, _ctx}} <-
          [Schema.resolve(claims)],
        into: MapSet.new(),
        do: id
  end

  defp resolve_call(set, call_id) do
    case Map.get(set, call_id) do
      {claims, _sig} -> Schema.resolve(claims)
      nil -> nil
    end
  end

  # ------------------------------------------------------------ line grammar

  # M4: "done" lines carry the tool NAME + the RESULT SUMMARY (first 80
  # chars) — args NEVER ride; asked/answered carry the content; called the
  # tool name; decided the verdict
  defp line(%{kind: :asked, content: content}), do: "asked: " <> normalize(content)
  defp line(%{kind: :answered, content: content}), do: "answered: " <> normalize(content)
  defp line(%{kind: :called, tool: tool}), do: "called: " <> tool
  defp line(%{kind: :done, tool: tool, result: result}), do: "done: " <> tool <> ": " <> String.slice(normalize(result), 0, 80)
  defp line(%{kind: :decided, verdict: verdict}), do: "decided: " <> verdict

  # whole-line rendering: embedded newlines normalize to spaces
  defp normalize(content) when is_binary(content), do: String.replace(content, ["\n", "\r"], " ")
  defp normalize(_other), do: ""

  # -------------------------------------------------------------- machinery

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  defp declared_type(%{pointers: pointers}) do
    Enum.find_value(pointers, fn
      %{role: "type", target: {:entity, name, _ctx}} -> name
      _other -> nil
    end)
  end
end
