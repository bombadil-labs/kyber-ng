defmodule Kyber.Agent.Prompt do
  @moduledoc """
  The prompt-assembly seam (T14c D2/D4) — a PURE module: the prompt the
  model sees is assembled from store state alone (no wall-clock, no
  ephemeral echo) and answered as a `PromptAssembled` store delta whose
  content is the canonical JSON of the message list — exactly what
  `LlmHandler.chat/3` receives. Re-derivation is a pure function of the
  delta set, so two boots over the same store produce byte-identical
  prompt answers (AC1).

  `assemble/4` is `Engine.build_messages/4` extracted verbatim, amended by
  the D4 ruling: the memory-notes gather is a SECOND gated surface, gated
  by a call-less mechanism — the memory epoch filters `memory_ids` before
  any note is built. Entity allowed => note included; entity not allowed =>
  omit-from-prompt, NO GateDecision minted (no call_id exists; omission is
  the call-less refusal grammar); epoch forked => omit ALL memory notes
  (fail-closed on fork); epoch absent (ungoverned) => include all — the
  legacy gather behavior is preserved (the recorded hole: the gather
  PREDATES governance, exactly as http tools did; the tool, born in this
  slice, is fail-closed by contrast).

  id->entity resolution is by CHAIN MEMBERSHIP (`Memory.resolve_set/2`),
  never the delta's direct entity pointer: the gather iterates memory DELTA
  ids while the retriever answers canon HEAD ids, and a canon head that is
  a `MemoryEdited` carries no entity pointer — membership is transitive
  over the edit chain. Under a governing epoch an id in NO resolvable
  chain is omitted (unprovable => fail-closed); under `:none` it is
  included (legacy).
  """

  alias Kyber.Agent.{ContextBuilder, Memory, Policy, Skill}
  alias Kyber.Agent.Memory.Assoc

  @system_prompt "You are kyber, an agent living in a claims substrate. " <>
                   "Ground your answer in the conversation and memory notes provided. " <>
                   "Use the provided tools when they help."

  @doc "The system prompt — relocated here with `build_messages/4` (the engine references it)."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc """
  Assemble the message list for one request from store state: conversation
  (windowed), memory notes (epoch-filtered per D4), summaries, and the
  elision note — in the engine's pinned order. `memory_ids` are the
  request's `memoryPointers`; the memory-epoch filter is a pure function of
  `set`, so AC1 byte-identity and the replay pre-check are unaffected (the
  stored claim still wins on replay even if the epoch changed after
  emission).
  """
  @spec assemble(Kyber.DeltaSet.t(), String.t(), [String.t()], non_neg_integer()) :: [map()]
  def assemble(set, session_id, memory_ids, window \\ 8, prompt_text \\ nil) do
    turns = ContextBuilder.conversation(set, session_id)
    {elided, windowed} = ContextBuilder.window(turns, window)

    memory_notes =
      for id <- gather_ids(set, memory_ids),
          {claims, _sig} <- [Map.get(set, id)],
          {:string, content} <- [pointer(claims, "content")],
          do: %{"role" => "system", "content" => "Memory: " <> content}

    summary_notes =
      for {_id, {claims, _sig}} <- Enum.sort_by(set, fn {_id, {c, _s}} -> c.timestamp end),
          declared_type(claims) == "ConversationSummary",
          match?({:entity, ^session_id, _}, pointer(claims, "sessionId")),
          {:string, content} <- [pointer(claims, "content")],
          do: %{"role" => "system", "content" => "Summary of earlier turns: " <> content}

    skill_notes = skill_notes(set, prompt_text)

    elision_note =
      case elided do
        [] -> []
        turns -> [%{"role" => "system", "content" => "#{length(turns)} earlier turns elided."}]
      end

    # the pinned order: system -> memory_notes -> summary_notes ->
    # skill_notes -> elision -> turns (M3)
    [%{"role" => "system", "content" => @system_prompt}] ++
      memory_notes ++
      summary_notes ++
      skill_notes ++
      elision_note ++
      Enum.map(windowed, &%{"role" => &1.role, "content" => &1.content})
  end

  @doc """
  Resolve the request's own promptRef'd delta content — the lens's
  PROMPT-RELATIVE query text (M3): the engine supplies the request's own
  prompt pointer's content, never the conversation tail (a resumed request
  would match the wrong turn). `nil` when the prompt delta is absent from
  the set — the lens then contributes nothing (fail-closed).
  """
  @spec prompt_text(Kyber.DeltaSet.t(), String.t()) :: String.t() | nil
  def prompt_text(set, prompt_id) do
    case Map.get(set, prompt_id) do
      {claims, _sig} ->
        case pointer(claims, "content") do
          {:string, content} -> content
          _other -> nil
        end

      nil ->
        nil
    end
  end

  # ------------------------------------------------ the skill lens (T14f D6)

  # the cap VALUES are pins (M4): 4 skills AND 8192 RENDERED note bytes,
  # skip-and-continue
  @skill_cap 4
  @skill_note_bytes 8192

  # the fail-closed lens (D6/N2): ungoverned AND forked epochs contribute NO
  # skills (L8 — the asymmetry with the memory gather's fail-open :none arm
  # is pinned; the two arms never unify); NO GateDecision is minted (the
  # lens is prompt assembly, not a gate). No prompt text => no skills ride.
  defp skill_notes(_set, nil), do: []

  defp skill_notes(set, prompt_text) when is_binary(prompt_text) do
    case Policy.skill_epoch(set) do
      {:ok, epoch} -> ranked_skill_notes(set, epoch, prompt_text)
      _none_or_forked -> []
    end
  end

  defp ranked_skill_notes(set, epoch, prompt_text) do
    query_digests = MapSet.new(Assoc.digests(prompt_text))

    set
    |> Skill.views()
    |> Enum.filter(&Policy.matches_skill?(epoch, &1.name))
    |> Enum.flat_map(fn view ->
      exact = String.contains?(prompt_text, view.name)
      shared = shared_digests(query_digests, view)

      # the exact-name tier is case-sensitive (L2); a mis-cased mention
      # falls through to the digest tier (which downcases) — intended
      if exact or shared >= 1 do
        [%{exact: exact, shared: shared, view: view}]
      else
        []
      end
    end)
    |> Enum.sort_by(fn %{exact: exact, shared: shared, view: view} ->
      # M1: exact-name tier first, then -shared_digest_count, ties on the
      # content-derived name — total and deterministic
      {if(exact, do: 0, else: 1), -shared, view.name}
    end)
    |> select_notes(%{count: 0, bytes: 0}, [])
    |> Enum.map(&%{"role" => "system", "content" => &1})
  end

  # the shared-digest count over the VIEW's name+description (D6: salience
  # over the views, never the raw streams; one tokenizer discipline —
  # Assoc.digests is CALLED, never re-implemented)
  defp shared_digests(query_digests, view) do
    view
    |> digest_source()
    |> Assoc.digests()
    |> Enum.count(&MapSet.member?(query_digests, &1))
  end

  defp digest_source(view), do: view.name <> " " <> view.description

  # M4: SKIP-AND-CONTINUE — a ranked skill that would blow either cap is
  # omitted entirely (never truncated), and SMALLER later skills may still
  # fit (stop-at-first-overflow rejected); 8192 counts the RENDERED note
  # bytes (the "Skill: <name>" prefix + description + body)
  defp select_notes([], _state, acc), do: Enum.reverse(acc)

  defp select_notes([%{view: view} | rest], %{count: count, bytes: bytes}, acc) do
    note = "Skill: " <> view.name <> "\n" <> view.description <> "\n" <> view.body
    note_bytes = byte_size(note)

    if count < @skill_cap and bytes + note_bytes <= @skill_note_bytes do
      select_notes(rest, %{count: count + 1, bytes: bytes + note_bytes}, [note | acc])
    else
      select_notes(rest, %{count: count, bytes: bytes}, acc)
    end
  end


  @doc """
  The canonical prompt bytes: stdlib `JSON.encode!` of the bare
  string-keyed message list — exactly what `LlmHandler.chat/3` receives.
  """
  @spec canonical([map()]) :: binary()
  def canonical(messages), do: JSON.encode!(messages)

  @doc """
  Decode a stored canonical prompt back to the message list. Validates
  every element is EXACTLY a two-string-key role/content map — reject,
  never repair: anything else is store corruption, never re-assembled.
  Returns `{:ok, messages}` or `{:error, :malformed}`.
  """
  @spec decode(binary()) :: {:ok, [map()]} | {:error, :malformed}
  def decode(binary) when is_binary(binary) do
    case JSON.decode(binary) do
      {:ok, messages} when is_list(messages) ->
        if Enum.all?(messages, &well_formed?/1),
          do: {:ok, messages},
          else: {:error, :malformed}

      _other ->
        {:error, :malformed}
    end
  end

  def decode(_), do: {:error, :malformed}

  # ------------------------------------------------------- the D4 filter

  # the call-less gate: epoch-filter the gather's memory ids BEFORE any
  # note is built (see the moduledoc for the full ruling)
  defp gather_ids(_set, memory_ids, :none), do: memory_ids
  defp gather_ids(_set, _memory_ids, {:error, :forked}), do: []

  defp gather_ids(set, memory_ids, {:ok, epoch}) do
    memories = Memory.resolve_set(set)

    Enum.filter(memory_ids, fn id ->
      case entity_for(memories, id) do
        nil ->
          # in NO resolvable chain under a governing epoch: unprovable =>
          # fail-closed, omit
          false

        entity_id ->
          Policy.check_memory(epoch, entity_id) == :allow
      end
    end)
  end

  defp gather_ids(set, memory_ids) do
    gather_ids(set, memory_ids, Policy.memory_epoch(set))
  end

  # chain membership: the memory whose chain contains the delta id — never
  # the delta's own entity pointer (a MemoryEdited canon head carries none)
  defp entity_for(memories, id) do
    case Enum.find(memories, &(id in &1.chain)) do
      %{entity: entity_id} -> entity_id
      nil -> nil
    end
  end

  # -------------------------------------------------------------- machinery

  # exactly a two-string-key role/content map — no third key, no extra
  # shape (reject, never repair)
  defp well_formed?(%{"role" => role, "content" => content} = map)
       when is_binary(role) and is_binary(content) do
    map_size(map) == 2
  end

  defp well_formed?(_other), do: false

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
