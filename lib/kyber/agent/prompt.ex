defmodule Kyber.Agent.Prompt do
  @moduledoc """
  The prompt-assembly seam (T14c D2/D4) — a PURE module: the prompt the
  model sees is assembled from store state alone (no wall-clock, no
  ephemeral echo) and answered as a `PromptAssembled` store delta whose
  content is the canonical JSON of the message list — exactly what
  `LlmHandler.chat/3` receives. Re-derivation is a pure function of the
  delta set, so two boots over the same store produce byte-identical
  prompt answers (AC1).

  `assemble/6` is `Engine.build_messages/4` extracted verbatim, amended by
  the D4 ruling: the memory-notes gather is a SECOND gated surface, gated
  by a call-less mechanism — the memory epoch filters `memory_ids` before
  any note is built. Entity allowed => note included; entity not allowed =>
  omit-from-prompt, NO GateDecision minted (no call_id exists; omission is
  the call-less refusal grammar); epoch forked => omit ALL memory notes
  (fail-closed on fork); epoch absent (ungoverned) => include all — the
  legacy gather behavior is preserved (the recorded hole: the gather
  PREDATES governance, exactly as http tools did; the tool, born in this
  slice, is fail-closed by contrast).

  T14g (R1/G3/G8): the 6th argument is the BOOT CONTEXT
  `{profile | nil, operator_author | nil}` — the identity block (the
  always-on block, FIRST after the system message, 8192 disjoint cap,
  never windowed) renders under it, the memory gather's `:none` arm FLIPS
  to omit-all under ANY active profile (N1 — the legacy fail-open arm stays
  for profile-less boots), and the skill lens sources its epoch from the
  profile's families under a profile (M2).

  id->entity resolution is by CHAIN MEMBERSHIP (`Memory.resolve_set/2`),
  never the delta's direct entity pointer: the gather iterates memory DELTA
  ids while the retriever answers canon HEAD ids, and a canon head that is
  a `MemoryEdited` carries no entity pointer — membership is transitive
  over the edit chain. Under a governing epoch an id in NO resolvable
  chain is omitted (unprovable => fail-closed); under `:none` it is
  included (legacy).

  ## Lens budget registry (T14j C4 — N4 governance)

  The lens caps are OPERATOR CONSTANTS — compile-time module attributes,
  changed by code review + rebuild, NEVER read from the store (a hostile
  store must never widen a cap). The registry names all FIVE lens caps:

  - identity block: 8192 rendered bytes (``Identity.@block_cap``,
    identity.ex — the always-on block's FIRST slot)
  - always-on block: 4096 rendered bytes (``@always_on_cap``, this module —
    standing/trajectory/open, disjoint from identity)
  - summary notes: 4096 rendered bytes (``@summary_cap``, this module —
    skip-whole)
  - skill notes: 4 skills (``@skill_cap``, this module — skip-and-continue)
  - skill notes: 8192 rendered bytes (``@skill_note_bytes``, this module)

  The two DISPATCH budgets are DELIBERATELY out-of-scope (N3): the
  reactor's per-turn dispatch cap 32 (``Reactor.@default_cap``) and the
  conversation window 8 (``ContextBuilder.window/2`` — the engine's
  ``@default_window``) govern DISPATCHING and WINDOWING, never lens bytes —
  they pool with no lens section. Per-section accounting (M7): each
  rendered section's bytes sit under ITS OWN cap while all sections
  coexist; a section over its cap is cut at ITS cap, never borrowing
  another section's budget.
  """

  alias Kyber.Agent.{ContextBuilder, Digest, Identity, Liveness, Memory, Policy, Profile, Skill, Standing}
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
  @spec assemble(
          Kyber.DeltaSet.t(),
          String.t(),
          [String.t()],
          non_neg_integer(),
          String.t() | nil,
          {String.t() | nil, String.t() | nil}
        ) :: [map()]
  def assemble(set, session_id, memory_ids, window \\ 8, prompt_text \\ nil, boot \\ {nil, nil}) do
    {profile_name, operator_author} = boot
    # the profile view is resolved ONCE per assemble (folds are recomputed
    # per read, never latched) and threads into the identity block, the
    # memory gather and the skill lens alike
    profile_view = profile_view(set, operator_author, profile_name)

    turns = ContextBuilder.conversation(set, session_id)
    {elided, windowed} = ContextBuilder.window(turns, window)

    identity_notes =
      for note <- Identity.block(set, operator_author, profile_view),
          do: %{"role" => "system", "content" => note}

    # T14h: the always-on block — computed BEFORE the gather so the standing
    # dedup (N1) reads the POST-CAP rendered standing entities (M7). The
    # block takes NO prompt_text input (AC1 by construction); the slot is
    # AFTER identity, BEFORE memory_notes.
    {always_on_notes, standing_entities} = always_on_notes(set, session_id, profile_view)

    memory_notes =
      for id <- gather_ids(set, memory_ids, profile_view, standing_entities),
          {claims, _sig} <- [Map.get(set, id)],
          {:string, content} <- [pointer(claims, "content")],
          do: %{"role" => "system", "content" => "Memory: " <> content}

    # T14h (A5 hardening): the summary gather is LIVENESS-FILTERED (the
    # shared recursive-existential oracle, author-blind — M6) and
    # `{ts, id}`-tie-broken (the probe-proven hash-map-order bug on
    # tied-ts stores), then capped 4096 skip-whole (M3). The liveness +
    # tie-break legs change bytes ONLY where today is buggy (AC-recorded);
    # the cap is the suite-probed safe bound.
    # T14j (C3): the gather is (session, PROFILE)-scoped — the summary
    # carries the profile key (the T14g profile name) and the filter is
    # nil == nil: an unkeyed legacy summary serves a {nil, nil} boot ONLY;
    # a keyed summary serves ONLY its own profile. AC-recorded byte delta:
    # "profiled boots no longer serve legacy unkeyed summaries".
    summary_notes =
      set
      |> Enum.filter(fn {id, {claims, _sig}} ->
        declared_type(claims) == "ConversationSummary" and
          match?({:entity, ^session_id, _}, pointer(claims, "sessionId")) and
          summary_profile(claims) == profile_name and
          Liveness.live?(set, id, fn _claims -> true end)
      end)
      |> Enum.sort_by(fn {id, {claims, _sig}} -> {claims.timestamp, id} end)
      |> select_summary_notes(0, [])
      |> Enum.map(fn {_id, {claims, _sig}} ->
        {:string, content} = pointer(claims, "content")
        %{"role" => "system", "content" => "Summary of earlier turns: " <> content}
      end)

    skill_notes = skill_notes(set, prompt_text, profile_view)

    elision_note =
      case elided do
        [] -> []
        turns -> [%{"role" => "system", "content" => "#{length(turns)} earlier turns elided."}]
      end

    # the pinned order (T14g G3 + T14h H3 — the T14f M3 parent pin,
    # byte-for-byte): system -> IDENTITY -> always-on -> memory_notes ->
    # summary_notes -> skill_notes -> elision -> turns
    [%{"role" => "system", "content" => @system_prompt}] ++
      identity_notes ++
      always_on_notes ++
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

  # T14j (C5): the N=4 name floor — the tool boundary AND the lens share
  # the SAME constant (the assoc.ex >=4-byte token floor is the derivation
  # anchor; the boundary measures byte_size of the POST-TRIM name, the
  # stored name is never normalized)
  @min_name_bytes 4

  # the fail-closed lens (D6/N2): ungoverned AND forked epochs contribute NO
  # skills (L8 — the asymmetry with the memory gather's fail-open :none arm
  # is pinned; the two arms never unify); NO GateDecision is minted (the
  # lens is prompt assembly, not a gate). No prompt text => no skills ride.
  defp skill_notes(_set, nil, _profile_view), do: []

  defp skill_notes(set, prompt_text, profile_view) when is_binary(prompt_text) do
    # T14g (M2): under a profile the lens's epoch source is the PROFILE's
    # families (the derived fail-closed defaults); profile-less boots keep
    # the boot families. Both answer `{:ok, epoch}` or nothing — the lens
    # stays fail-closed either way.
    epoch =
      case profile_view do
        nil ->
          case Policy.skill_epoch(set) do
            {:ok, epoch} -> {:ok, epoch}
            other -> other
          end

        view ->
          Profile.skill_epoch(set, view)
      end

    case epoch do
      {:ok, epoch} -> ranked_skill_notes(set, epoch, prompt_text)
      _none_or_forked -> []
    end
  end

  defp ranked_skill_notes(set, epoch, prompt_text) do
    query_digests = MapSet.new(Assoc.digests(prompt_text))

    set
    |> Skill.views()
    |> Enum.filter(&Policy.matches_skill?(epoch, &1.name))
    # T14j (C5): the read-side twin — out-of-band sub-floor names (hand-
    # crafted store state; the door refuses only "") are LENS-INERT: the
    # N=4 boundary and the tokenizer speak the same units, and a sub-4 name
    # is digest-blind (Assoc.digests == []) so the exact tier is its only
    # path — the floor makes it permanently inert.
    |> Enum.filter(&(byte_size(String.trim(&1.name)) >= @min_name_bytes))
    |> Enum.flat_map(fn view ->
      # T14j (C5/H1): the exact-name tier is the boundary-anchored
      # case-sensitive literal lookaround (L2 preserved): the name is
      # Regex.escape'd BEFORE interpolation — "foo.bar" matches "see
      # foo.bar here" and NEVER "see foo bar here" or "fooXbar"; a
      # single- AND multi-token name both ride whole-token only.
      exact =
        Regex.match?(
          ~r/(?<![A-Za-z0-9])#{Regex.escape(view.name)}(?![A-Za-z0-9])/,
          prompt_text
        )

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

  # ------------------------------------------------ the always-on block (T14h)

  # H3: the THIRD budget — 4096 TOTAL rendered bytes, disjoint from the
  # identity block's 8192 and the skill lens's 8192, never pooled. Claim
  # order (M1): Standing first, Trajectory second, Open last — the header
  # order, each section claiming against the 4096 in sequence.
  @always_on_cap 4096

  # M3: the A5 summary cap — SKIP-WHOLE 4096 (the suite-probed safe bound:
  # engine_test.exs:205's window-lens test needs ~80 bytes of headroom).
  @summary_cap 4096

  # the always-on block: {notes, standing_entities} — the notes render in
  # the pinned header order; standing_entities is the POST-CAP rendered
  # standing set (M7 — the dedup's input). Absence, never an empty header.
  defp always_on_notes(set, session_id, profile_view) do
    {standing_note, standing_entities, budget} = standing_section(Standing.fold(set, profile_view))
    {trajectory_note, budget} = trajectory_section(Digest.head(set, session_id), budget)
    open_note = open_section(Standing.open(set, session_id), budget)

    {Enum.reject([standing_note, trajectory_note, open_note], &is_nil/1), standing_entities}
  end

  # SKIP-WHOLE (H3 — standing is independent items; greed is fine): a line
  # that would blow the cap is omitted ENTIRELY, smaller later lines still
  # fit; standing renders in {ts, id} ASCENDING order (M7).
  defp standing_section(items) do
    {lines, entities} =
      Enum.reduce(items, {[], []}, fn item, {lines, entities} ->
        line = "- " <> item.entity <> ": " <> item.content

        if byte_size(render_section("Standing:", lines ++ [line])) <= @always_on_cap do
          {lines ++ [line], entities ++ [item.entity]}
        else
          {lines, entities}
        end
      end)

    case lines do
      [] ->
        {nil, [], @always_on_cap}

      _ ->
        content = render_section("Standing:", lines)
        {%{"role" => "system", "content" => content}, entities, @always_on_cap - byte_size(content)}
    end
  end

  # the trajectory = the digest head's content, ONE message (the mint's
  # contiguous-stop already bounded it at 2048); at read the whole section
  # claims the remaining budget — omit-whole when it would not fit.
  defp trajectory_section(:none, budget), do: {nil, budget}

  defp trajectory_section({:ok, content}, budget) do
    note = render_section("Trajectory:", [content])

    if byte_size(note) <= budget do
      {%{"role" => "system", "content" => note}, budget - byte_size(note)}
    else
      {nil, budget}
    end
  end

  # CONTIGUOUS-STOP over the pinned {ts, id} ASCENDING order (M1): a hole
  # in a thread list lies about open work — never skip-whole; the sequence
  # stops at the first line that would blow the remaining budget.
  defp open_section(threads, budget) do
    lines =
      Enum.reduce_while(threads, [], fn thread, acc ->
        line = if thread.waiting, do: "- " <> thread.content <> " (tool waiting)", else: "- " <> thread.content

        if byte_size(render_section("Open:", acc ++ [line])) <= budget do
          {:cont, acc ++ [line]}
        else
          {:halt, acc}
        end
      end)

    case lines do
      [] -> nil
      _ -> %{"role" => "system", "content" => render_section("Open:", lines)}
    end
  end

  defp render_section(header, lines), do: header <> "\n" <> Enum.join(lines, "\n")

  # M3: the A5 summary cap — SKIP-WHOLE over the RENDERED note bytes
  # ("Summary of earlier turns: " <> content)
  defp select_summary_notes([], _bytes, acc), do: Enum.reverse(acc)

  defp select_summary_notes([{_id, {claims, _sig}} = element | rest], bytes, acc) do
    {:string, content} = pointer(claims, "content")
    note_bytes = byte_size("Summary of earlier turns: " <> content)

    if bytes + note_bytes <= @summary_cap do
      select_summary_notes(rest, bytes + note_bytes, [element | acc])
    else
      select_summary_notes(rest, bytes, acc)
    end
  end

  # ------------------------------------------------------- the D4 filter

  # the call-less gate: epoch-filter the gather's memory ids BEFORE any
  # note is built (see the moduledoc for the full ruling)
  # T14g (R1/G8/N1): the :none gather arm FLIPS under a profile — the legacy
  # fail-open include-all stays for profile-less boots (byte-identical
  # legacy behavior); under ANY active profile the epoch source is the
  # profile's families (UNION, M3) and an ungoverned union governs NOTHING
  # (omit-all — the AC2 leak through the gather is closed).
  # T14h (N1/M7): the standing dedup rides OUTSIDE the epoch arms — a
  # memory id whose chain resolves to an entity ALREADY RENDERED standing
  # (POST-CAP) is dropped from the gather: standing wins. A standing line
  # dropped by the 4096 skip-whole never drops its memory note (the entity
  # never vanishes from the prompt entirely).
  defp gather_ids(set, memory_ids, profile_view, standing_entities) do
    memories = Memory.resolve_set(set)

    set
    |> gather_ids(memory_ids, profile_view)
    |> Enum.reject(fn id ->
      case entity_for(memories, id) do
        nil -> false
        entity_id -> entity_id in standing_entities
      end
    end)
  end

  defp gather_ids(set, memory_ids, nil), do: gather_ids(set, memory_ids, Policy.memory_epoch(set))

  defp gather_ids(set, memory_ids, %{name: _name} = profile_view) do
    {:ok, epoch} = Profile.memory_epoch(set, profile_view)
    gather_ids(set, memory_ids, {:ok, epoch})
  end

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

  # chain membership: the memory whose chain contains the delta id — never
  # the delta's own entity pointer (a MemoryEdited canon head carries none)
  defp entity_for(memories, id) do
    case Enum.find(memories, &(id in &1.chain)) do
      %{entity: entity_id} -> entity_id
      nil -> nil
    end
  end

  # ------------------------------------------------- the replay key (N2/H3)

  @doc """
  The replay key's MATERIAL (T14h N2/H3): `nil` for profile-less boots
  (T14g M4 — profile-less mints stay byte-identical, no new pointers);
  otherwise `%{profile: name, roster: <canonical JSON of the SORTED
  {family, epoch-id} pairs>, head: <ProfileSet head id | nil>}`. The
  roster covers the profile's NAMED families, each epoch id resolved via
  `Policy.current/2` — never the union epoch's `nil` id (profile.ex:140:
  the union epoch has `id: nil`, so any key reading "the epoch id" is
  unimplementable and rotation-blind). The key rides ONLY under a profile;
  the digest id is NEVER the key.
  """
  @spec replay_key(Kyber.DeltaSet.t(), {String.t() | nil, String.t() | nil}) :: map() | nil
  def replay_key(_set, {nil, _operator_author}), do: nil

  def replay_key(set, {profile_name, operator_author})
      when is_binary(profile_name) and is_binary(operator_author) do
    case Profile.resolve(set, operator_author, profile_name) do
      {:ok, view} ->
        roster =
          for family <- view.families do
            epoch_id =
              case Policy.current(set, family) do
                {:ok, epoch} -> epoch.id
                _none_or_forked -> nil
              end

            {family, epoch_id}
          end

        # canonical JSON of the SORTED pairs — arrays, never tuples (JSON
        # cannot encode Elixir tuples)
        roster_json =
          roster
          |> Enum.sort()
          |> Enum.map(fn {family, epoch_id} -> [family, epoch_id] end)
          |> JSON.encode!()

        %{profile: profile_name, roster: roster_json, head: view.head}

      :not_found ->
        %{profile: profile_name, roster: "[]", head: nil}
    end
  end

  # the nil-operator-seed leg under a bound profile: fail-closed, no view —
  # the key is still deterministic (an empty material keys nothing verifiable
  # and matches itself on re-boot)
  def replay_key(_set, {profile_name, _nil_author}) when is_binary(profile_name) do
    %{profile: profile_name, roster: JSON.encode!([]), head: nil}
  end

  def replay_key(_set, _boot), do: nil

  # ----------------------------------------------------- the boot context

  # resolve the boot profile's ProfileSet view once per assemble; nil when
  # profile-less OR the operator author is absent (the nil-seed leg is
  # fail-closed: no operator seed => no identity block, no profile view)
  defp profile_view(_set, _operator_author, nil), do: nil
  defp profile_view(_set, nil, _profile_name), do: nil

  defp profile_view(set, operator_author, profile_name) do
    case Profile.resolve(set, operator_author, profile_name) do
      {:ok, view} -> view
      :not_found -> nil
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

  # the summary's profile key: the optional `profile` string role — nil for
  # unkeyed (legacy) summaries; the gather's (session, profile) filter
  # compares nil == nil, so keyed-vs-unkeyed is a MISS, never a cross-serve
  defp summary_profile(claims) do
    case pointer(claims, "profile") do
      {:string, profile} -> profile
      _none -> nil
    end
  end
end
