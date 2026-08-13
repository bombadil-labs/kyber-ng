defmodule Kyber.Agent.Events do
  @moduledoc """
  Claim templates for the T11b inference chain, mirroring `Kyber.Events`:
  each builder returns `{:ok, {claims, sig_hex}}`, validated at the boundary
  and signed by the agent's key. Every template matches its genesis schema
  (`Kyber.Schema.Genesis`) exactly — closed validation is what structurally
  keeps conversation text out of these deltas (composites point).

  Pointer order is the template (array order is part of the content
  address): the KIND MARKER — the role the gather routes on — rides first,
  the T11a `type` declaration rides last. Kind markers: `InferenceRequested`
  routes as `"promptRef"`, `ResponseDelta` as `"requestRef"`, `ToolCall` as
  `"tool"`, `ToolResult` as `"call"`, `ConversationSummary` as
  `"sessionId"`, `MemoryEntity` as `"entity"`, `MemoryEdited` as `"edits"`,
  `GateDecision` as `"decides"`.
  """

  alias Rhizomatic.Delta
  alias Kyber.Keys

  @type signed :: {Delta.claims(), String.t()}

  @doc """
  `InferenceRequested` — the context builder asks for a model turn. THIN by
  schema: the prompt, the conversation head, and the memories are pointers;
  the engine rehydrates content from the store.
  """
  @spec inference_requested(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [
            String.t()
          ]
        ) :: {:ok, signed()} | {:error, term()}
  def inference_requested(seed, ts, model, session_id, conversation_ref, prompt_id, memory_ids) do
    build(seed, ts, "InferenceRequested", [
      %{role: "promptRef", target: {:delta, prompt_id, "requested"}},
      %{role: "model", target: {:string, model}},
      %{role: "sessionId", target: {:entity, session_id, "inferences"}},
      %{role: "conversationRef", target: {:delta, conversation_ref, "context_of"}},
      Enum.map(memory_ids, &%{role: "memoryPointers", target: {:delta, &1, "informed"}})
    ])
  end

  @doc "`ResponseDelta` — the model's answer, pointer-linked to its request."
  @spec response_delta(String.t(), number(), String.t(), number(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def response_delta(seed, ts, request_id, index, content, memory_used) do
    build(seed, ts, "ResponseDelta", [
      %{role: "requestRef", target: {:delta, request_id, "answered"}},
      %{role: "index", target: {:number, 1.0 * index}},
      %{role: "content", target: {:string, content}},
      Enum.map(memory_used, &%{role: "memoryUsed", target: {:delta, &1, "informed"}})
    ])
  end

  @doc "`ToolCall` — the model wants a tool run mid-turn, linked to its request."
  @spec tool_call(String.t(), number(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def tool_call(seed, ts, tool_id, args, request_id) do
    build(seed, ts, "ToolCall", [
      %{role: "tool", target: {:entity, tool_id, "calls"}},
      %{role: "args", target: {:string, args}},
      %{role: "requestRef", target: {:delta, request_id, "tool_use"}}
    ])
  end

  @doc "`ToolResult` — the executor's answer, pointer-linked to its call."
  @spec tool_result(String.t(), number(), String.t(), String.t(), String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def tool_result(seed, ts, call_id, result, status \\ nil) do
    build(seed, ts, "ToolResult", [
      %{role: "call", target: {:delta, call_id, "result"}},
      %{role: "result", target: {:string, result}},
      if(status, do: [%{role: "status", target: {:string, status}}], else: [])
    ])
  end

  @doc """
  `GateDecision` — the permission gate's attested decision on a `ToolCall`
  (T12): `allow` / `deny` / `refuse`, pointer-linked to the call it
  decides. Every decision is a delta (auditable); a denied or refused call
  emits NO `ToolResult` — reject, never repair. T14b: `url_policy`
  refusals carry the deciding epoch as an optional `policy_epoch` pointer
  (a refusal-shape extension; existing call sites byte-unchanged).
  """
  @spec gate_decision(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, signed()} | {:error, term()}
  def gate_decision(seed, ts, call_id, verdict, policy, reason \\ nil, policy_epoch \\ nil) do
    build(seed, ts, "GateDecision", [
      %{role: "decides", target: {:delta, call_id, "decided"}},
      %{role: "verdict", target: {:string, verdict}},
      %{role: "policy", target: {:string, policy}},
      if(reason, do: [%{role: "reason", target: {:string, reason}}], else: []),
      if(policy_epoch,
        do: [%{role: "policy_epoch", target: {:delta, policy_epoch, "under"}}],
        else: []
      )
    ])
  end

  @doc """
  `Policy` — a governance epoch as a store claim (T14b): exact downcased
  hosts, explicit schemes (no default exists — zero `allow_scheme`
  pointers refuses all gated calls), optional `supersedes` pointer to the
  epoch it replaces. Revocation is retraction (`negates`), never deletion.
  """
  @spec policy(String.t(), number(), String.t(), [String.t()], [String.t()], String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def policy(seed, ts, family, allow_hosts, allow_schemes, supersedes \\ nil) do
    build(seed, ts, "Policy", [
      %{role: "policy", target: {:entity, family, "epoch"}},
      Enum.map(allow_hosts, &%{role: "allow_host", target: {:string, String.downcase(&1)}}),
      Enum.map(allow_schemes, &%{role: "allow_scheme", target: {:string, &1}}),
      if(supersedes,
        do: [%{role: "supersedes", target: {:delta, supersedes, "superseded"}}],
        else: []
      )
    ])
  end

  @doc """
  `ToolCallDuplicate` — a duplicate `ToolCall` observed (T14b): the stored
  answer is re-emitted byte-identical, the duplicate recorded, the action
  never re-run. Claims the CALL's timestamp, so every duplicate derives
  the same observation id and merge-is-union yields exactly one record.
  """
  @spec tool_call_duplicate(String.t(), number(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def tool_call_duplicate(seed, ts, call_id, result_id) do
    build(seed, ts, "ToolCallDuplicate", [
      %{role: "dedupes", target: {:delta, call_id, "deduplicated"}},
      %{role: "result", target: {:delta, result_id, "observed"}}
    ])
  end

  @doc """
  `ConversationSummary` — a lens artifact covering elided turns. T14j (C3):
  the summary rides the PROFILE key — the optional `profile` string role
  (the T14g profile name) emits ONLY under a profile (profile-less mints
  stay byte-identical; `nil` omits the pointer entirely). The (session,
  profile) key is the gather's filter: keyed-vs-unkeyed is a MISS, never a
  cross-serve.
  """
  @spec conversation_summary(
          String.t(),
          number(),
          String.t(),
          String.t(),
          [String.t()],
          String.t() | nil
        ) :: {:ok, signed()} | {:error, term()}
  def conversation_summary(seed, ts, session_id, content, covers, profile \\ nil) do
    build(seed, ts, "ConversationSummary", [
      %{role: "sessionId", target: {:entity, session_id, "summaries"}},
      %{role: "content", target: {:string, content}},
      Enum.map(covers, &%{role: "covers", target: {:delta, &1, "summarized"}}),
      if(profile, do: [%{role: "profile", target: {:string, profile}}], else: [])
    ])
  end

  @doc "`MemoryEntity` — a remembered fact about an entity (T11c's container will emit these)."
  @spec memory_entity(String.t(), number(), String.t(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def memory_entity(seed, ts, entity_id, content, sources) do
    build(seed, ts, "MemoryEntity", [
      %{role: "entity", target: {:entity, entity_id, "memories"}},
      %{role: "content", target: {:string, content}},
      Enum.map(sources, &%{role: "source", target: {:delta, &1, "remembered"}})
    ])
  end

  @doc """
  `MemoryEdited` — a memory's canon superseded by an edit (T11c's watcher
  emits these for out-of-band human edits). The genesis schema is closed:
  the OLD content rides by pointer (`edits` targets the superseded canon
  delta — composites point), the NEW content rides inline, and the source
  attestation (`human_edit`) rides the schema's `reason` role.
  """
  @spec memory_edited(String.t(), number(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def memory_edited(seed, ts, edited_id, content, reason \\ "human_edit") do
    build(seed, ts, "MemoryEdited", [
      %{role: "edits", target: {:delta, edited_id, "edited"}},
      %{role: "content", target: {:string, content}},
      %{role: "reason", target: {:string, reason}}
    ])
  end

  @doc """
  `SkillSet` — one full-set skill write (T14f D1): the WHOLE property set
  (name/description/body) plus optional `metadata` (a JSON string) and an
  optional `source` provenance pointer (the triggering `ToolCall`'s id —
  `{:delta, call, "triggered"}`, the MemoryEntity precedent). The name rides
  as the aggregate key (`{:entity, name, "skills"}` — content-derived
  identity). A skill is NOT a delta — it is a VIEW over its delta stream, so
  a `SkillSet` supersedes the previous full-set delta of the same name
  whole-set (H6): an ABSENT optional role is CLEARED. `ts` is the triggering
  delta's `claims.timestamp` (the call's), never a fresh clock (M6 — a
  crash-window re-fire must re-mint the SAME delta so record-dedupe holds).
  """
  @spec skill_set(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, signed()} | {:error, term()}
  def skill_set(seed, ts, name, description, body, metadata \\ nil, source \\ nil) do
    build(seed, ts, "SkillSet", [
      %{role: "skill", target: {:entity, name, "skills"}},
      %{role: "description", target: {:string, description}},
      %{role: "body", target: {:string, body}},
      if(metadata, do: [%{role: "metadata", target: {:string, metadata}}], else: []),
      if(source, do: [%{role: "source", target: {:delta, source, "triggered"}}], else: [])
    ])
  end

  @doc """
  `SkillRetract` — a delta-ID-targeted negation of a skill's order-head
  set-delta (T14f D4/H2): retraction-is-negation, never delete-a-blob; the
  grammar has no name form, so the fold's liveness is recursive-existential
  through the whole negation chain (restore = retract the retraction; a
  non-head retraction is a silent no-op). The `negates` target is the head
  `SkillSet`'s content id. `ts` is the triggering call's `claims.timestamp`
  (M6).
  """
  @spec skill_retract(String.t(), number(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def skill_retract(seed, ts, name, head_id) do
    build(seed, ts, "SkillRetract", [
      %{role: "skill", target: {:entity, name, "skills"}},
      %{role: "negates", target: {:delta, head_id, "retracted"}}
    ])
  end

  @doc """
  `IdentitySet` — one full-set identity write (T14g G2): the soul/user/
  operator primitives are DERIVED entities, a view over their `IdentitySet`
  delta stream (never a blob). The `entity` pointer (`identity:<id>`) is
  the binding (one entity per primitive; the role name `entity` is the
  MemoryEntity precedent, pinned deliberately); the `kind` field is the
  CLOSED fold key (soul/user/operator — an unknown kind is FOLD-INERT);
  `body` is the rendered text; `source` is the optional provenance pointer.
  The claims are OPERATOR-ATTESTED (G7): the fold pre-filters to the boot-
  constant author (R1/H2), so an agent-signed write is door-admissible but
  never renders (AC3's rejection = fold-inertness, M6). Whole-set supersede
  per T14f H6: the latest live set-delta of the kind wins.
  """
  @spec identity_set(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: {:ok, signed()} | {:error, term()}
  def identity_set(seed, ts, id, kind, body, source \\ nil) do
    build(seed, ts, "IdentitySet", [
      %{role: "entity", target: {:entity, id, "identity"}},
      %{role: "kind", target: {:string, kind}},
      %{role: "body", target: {:string, body}},
      if(source, do: [%{role: "source", target: {:delta, source, "attested"}}], else: [])
    ])
  end

  @doc """
  `ProfileSet` — one profile declaration delta (T14g G2/G5/G8): a profile
  is a POLICY-SHAPED BINDING — identity view + epoch-bounded memory/skill
  visibility + capability subset — never a storage mechanism. The name
  rides as the `profile` entity aggregate key (the ATTACH key); `rules` is
  the rendered profile-rules text (the always-on block's
  `"Profile: <name>\n"` segment); `rides` are `identity:<id>` ENTITY REFS
  (which primitives the profile rides); `allow_tool` and `families` are
  strings (the capability subset / the live family-name epoch refs).
  Declarations are OPERATOR-ATTESTED (H2c): the fold pre-filters to the
  boot-constant author — an agent-declared ProfileSet is fold-inert and
  can never escalate visibility.
  """
  @spec profile_set(
          String.t(),
          number(),
          String.t(),
          String.t(),
          [String.t()],
          [String.t()],
          [String.t()]
        ) :: {:ok, signed()} | {:error, term()}
  def profile_set(seed, ts, name, rules, rides \\ [], allow_tool \\ [], families \\ []) do
    build(seed, ts, "ProfileSet", [
      %{role: "profile", target: {:entity, name, "profiles"}},
      %{role: "rules", target: {:string, rules}},
      Enum.map(rides, &%{role: "rides", target: {:entity, &1, "rides"}}),
      Enum.map(allow_tool, &%{role: "allow_tool", target: {:string, &1}}),
      Enum.map(families, &%{role: "families", target: {:string, &1}})
    ])
  end

  @doc """
  `PromptAssembled` — the prompt-as-delta claim (T14c D1): the assembled
  prompt the model SAW, answered as a store delta. `sessionId` FIRST (the
  kind-marker grammar — `"sessionId"` routes to no subscription and matches
  no lens; the two `requestRef` readers, `Engine.answered?/2` and the
  conversation lens, key on the FIRST role). `content` is the canonical
  JSON of the message list (`Kyber.Agent.Prompt.canonical/1`) — exactly
  what `LlmHandler.chat/3` receives. `ts` is the triggering
  `InferenceRequested` delta's `claims.timestamp`, never wall-clock; ONE
  claim per (assembled prompt, profile, roster).

  T14g (N2/H4): the claim is PROFILE-KEYED — the optional `profile` string
  role rides ONLY under a profile (profile-less mints stay BYTE-IDENTICAL:
  `profile == nil` emits no pointer); keyed-vs-unkeyed is a MISS at the
  replay check, never a cross-serve (a legacy unkeyed claim never serves a
  profiled boot and vice versa).

  T14h (N5/H3): the key EXTENDS to the (profile, sorted {family, epoch-id}
  roster + ProfileSet head id) material — the optional `replayKey` delta
  role points at the `EpochKeyMaterial` delta's content id (the /7 arity),
  emitted ONLY under a profile; profile-less mints stay BYTE-IDENTICAL
  (`profile == nil` and `replay_key == nil` emit no pointers). The digest
  id is NEVER the key.
  """
  @spec prompt_assembled(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, signed()} | {:error, term()}
  def prompt_assembled(seed, ts, request_id, session_id, content, profile \\ nil, replay_key \\ nil) do
    build(seed, ts, "PromptAssembled", [
      %{role: "sessionId", target: {:entity, session_id, "prompts"}},
      %{role: "requestRef", target: {:delta, request_id, "prompted"}},
      %{role: "content", target: {:string, content}},
      if(profile, do: [%{role: "profile", target: {:string, profile}}], else: []),
      if(replay_key, do: [%{role: "replayKey", target: {:delta, replay_key, "keyed"}}], else: [])
    ])
  end

  @doc """
  `StandingDigest` — the trajectory view (T14h H5/N5): a per-answer mint
  over the session's covered delta set ({MessageReceived, ResponseDelta,
  ToolCall, ToolResult, GateDecision}, liveness-filtered, session-scoped),
  whole-set supersede by `{ts, id}` (NO `supersedes` pointer — the T14g G2
  norm; two live same-session heads resolve latest-wins, never a fork
  error). `sessionId` FIRST (routes to no subscription, matches no lens —
  the minter never observes its own output); `content` is the POST-CAP
  rendered trajectory (N=16 items newest-first, 2048-byte contiguous stop);
  `covers` = EXACTLY the rendered lines' deltas (M8). `ts` is the
  triggering `InferenceRequested` delta's `claims.timestamp`, never
  wall-clock (H2) — a crash-window re-fire re-mints the same content + same
  ts => same content id => merge-is-union collapses to one digest.
  """
  @spec standing_digest(String.t(), number(), String.t(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def standing_digest(seed, ts, session_id, content, covers) do
    build(seed, ts, "StandingDigest", [
      %{role: "sessionId", target: {:entity, session_id, "digests"}},
      %{role: "content", target: {:string, content}},
      Enum.map(covers, &%{role: "covers", target: {:delta, &1, "covered"}})
    ])
  end

  @doc """
  `StandingFlag` — the standing salience marker (T14h H4): flags a memory
  entity as standing (the always-on fold's input). The `"standing"` kind
  marker routes to no subscription. Unflag = negate the flag
  (retraction-is-negation), never identity surgery; re-flag after removal
  rides with no special case. Whitespace-only entity ids are FOLD-INERT.
  """
  @spec standing_flag(String.t(), number(), String.t()) :: {:ok, signed()} | {:error, term()}
  def standing_flag(seed, ts, entity_id) do
    build(seed, ts, "StandingFlag", [
      %{role: "standing", target: {:entity, entity_id, "standing"}}
    ])
  end

  @doc """
  `EpochKeyMaterial` — the replay key's material (T14h N2/H3): the delta
  carrying the profile's SORTED `{family, epoch-id}` roster (canonical JSON
  of the pairs over the profile's NAMED families, resolved via
  `Policy.current/2` — never the union epoch's nil id) + the ProfileSet
  head id (the declaration's own head — the T14g latest-wins fold). The
  content-derived id IS the key's material form: match-or-rederive
  compares ids, and the digest id is NEVER the key. Emitted ONLY under a
  profile (profile-less mints stay byte-identical — T14g M4).
  """
  @spec epoch_key_material(String.t(), number(), String.t(), String.t(), String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def epoch_key_material(seed, ts, profile, roster_json, head) do
    build(seed, ts, "EpochKeyMaterial", [
      %{role: "profile", target: {:string, profile}},
      %{role: "roster", target: {:string, roster_json}},
      if(head, do: [%{role: "head", target: {:delta, head, "declared"}}], else: [])
    ])
  end

  @doc """
  `Policy` — the memory-family governance epoch (T14c D3): type `"Policy"`
  over the `{:entity, "memory", "epoch"}` target, the allow-list riding
  `allow_entity` roles (`{:entity, entity_id, "readable"}`), optional
  `supersedes`. Zero `allow_entity` pointers => refuse all gated reads. NO
  downcase on entity ids (the T14b downcase pin is host-specific). The
  epoch's `ts` is caller-derived (the operator's store clock, never
  wall-clock in the decision surface).
  """
  @spec memory_policy(String.t(), number(), [String.t()], String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def memory_policy(seed, ts, allow_entities, supersedes \\ nil) do
    build(seed, ts, "Policy", [
      %{role: "policy", target: {:entity, "memory", "epoch"}},
      Enum.map(allow_entities, &%{role: "allow_entity", target: {:entity, &1, "readable"}}),
      if(supersedes,
        do: [%{role: "supersedes", target: {:delta, supersedes, "superseded"}}],
        else: []
      )
    ])
  end

  @doc """
  `Policy` — the skill-family governance epoch (T14f D5): the memory-family
  pattern over the `{:entity, "skill", "epoch"}` target, the allow-list
  riding `allow_entity` roles (`{:entity, name, "writable"}` — the context
  is stripped at epoch compile; ONE allowlist governs all three skill
  surfaces, L3). ZERO Policy genesis change — the `allow_entity` role
  already exists; the family name disambiguates skill entities from memory
  entities. The epoch's `ts` is caller-derived (the operator's store clock,
  never wall-clock in the decision surface).
  """
  @spec skill_policy(String.t(), number(), [String.t()], String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def skill_policy(seed, ts, allow_names, supersedes \\ nil) do
    build(seed, ts, "Policy", [
      %{role: "policy", target: {:entity, "skill", "epoch"}},
      Enum.map(allow_names, &%{role: "allow_entity", target: {:entity, &1, "writable"}}),
      if(supersedes,
        do: [%{role: "supersedes", target: {:delta, supersedes, "superseded"}}],
        else: []
      )
    ])
  end

  @doc """
  `BootAttestation` — the operator-key boot attestation (T14c D5): the
  operator's key ATTESTS the agent's boot (it never authorizes — it appears
  in no gate decision), signed with the OPERATOR seed. EXACTLY three
  pointers: `operator` -> `{:entity, operator_author, "attests"}`,
  `agent` -> `{:entity, agent_author, "attested"}`,
  `boot` -> `{:delta, seed_claim_id, "booted_under"}`. `ts` is the seed
  claim's `claims.timestamp` — the only store-derived clock at boot — so
  reboots over one store merge to exactly one attestation.
  """
  @spec boot_attestation(String.t(), number(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def boot_attestation(operator_seed, ts, agent_author, seed_claim_id) do
    build(operator_seed, ts, "BootAttestation", [
      %{role: "operator", target: {:entity, Keys.author_for_seed(operator_seed), "attests"}},
      %{role: "agent", target: {:entity, agent_author, "attested"}},
      %{role: "boot", target: {:delta, seed_claim_id, "booted_under"}}
    ])
  end

  # T17: the AgentSet field vocabulary — pointer emission order is FIXED
  # (array order is part of the content address; a reordered map must not
  # re-address the delta)
  @agent_fields ~w(soul base_url model api_key_env api_key_enc system_prompt operator_seed_env oracle_seed loop channel_socket profile self_config)a

  @doc """
  `AgentSet` — one agent-identity SET delta (T17): the agent's operational
  identity is an entity folded over its own delta stream (no config file).
  Each delta carries ONLY the fields it changes (`fields` is a map over
  #{inspect(@agent_fields)} plus `unset: [names]`); the fold merges
  per-field, last-set-wins. The name rides as the `agent` entity aggregate
  key (kind marker first). Secret fields are env NAMES or ciphertext, never
  plaintext (door-refused upstream, AC17).
  """
  @spec agent_set(String.t(), number(), String.t(), map()) ::
          {:ok, signed()} | {:error, term()}
  def agent_set(seed, ts, name, fields) do
    build(seed, ts, "AgentSet", [
      %{role: "agent", target: {:entity, name, "agents"}},
      Enum.flat_map(@agent_fields, fn field ->
        case Map.get(fields, field) do
          nil -> []
          value -> [%{role: Atom.to_string(field), target: {:string, value}}]
        end
      end),
      Enum.map(Map.get(fields, :unset, []), &%{role: "unset", target: {:string, &1}})
    ])
  end

  @doc """
  `AgentRetract` — the delta-ID-targeted negation of an `AgentSet` delta
  (T17, the SkillRetract mirror): retraction-is-negation; the fold steps
  back PER FIELD to the previous live setter; restore = retract the
  retraction (recursive-existential liveness).
  """
  @spec agent_retract(String.t(), number(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def agent_retract(seed, ts, name, target_id) do
    build(seed, ts, "AgentRetract", [
      %{role: "agent", target: {:entity, name, "agents"}},
      %{role: "negates", target: {:delta, target_id, "retracted"}}
    ])
  end

  @doc """
  `ConfigRollback` — the safety harness's rollback notification (T17 AC12):
  the offending delta ids, the classifier's reason, and the restored field
  values. Surfaces in `ctl tail`/`status`; the user is always told.
  """
  @spec config_rollback(String.t(), number(), String.t(), String.t(), [String.t()], [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def config_rollback(seed, ts, name, reason, offends, restored) do
    build(seed, ts, "ConfigRollback", [
      %{role: "rollback", target: {:entity, name, "rollbacks"}},
      %{role: "reason", target: {:string, reason}},
      Enum.map(offends, &%{role: "offends", target: {:delta, &1, "rolled_back"}}),
      Enum.map(restored, &%{role: "restored", target: {:string, &1}})
    ])
  end

  @doc """
  `SecretTombstone` — the secret-exposure record (T17 AC24): the operator
  retracts the offending delta, appends this tombstone (delta id, field,
  optional rotated-key pointer), and rotates the credential. The runbook is
  part of the build, not discovered after the incident.
  """
  @spec secret_tombstone(String.t(), number(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, signed()} | {:error, term()}
  def secret_tombstone(seed, ts, name, delta_id, field, rotated \\ nil) do
    build(seed, ts, "SecretTombstone", [
      %{role: "tombstone", target: {:delta, delta_id, "exposed"}},
      %{role: "agent", target: {:entity, name, "agents"}},
      %{role: "field", target: {:string, field}},
      if(rotated, do: [%{role: "rotated", target: {:string, rotated}}], else: [])
    ])
  end

  # ---------------------------------------------------------------- helpers

  defp build(seed, ts, type, pointers) do
    with {:ok, ts} <- timestamp(ts) do
      claims = %{
        timestamp: ts,
        author: Keys.author_for_seed(seed),
        pointers:
          List.flatten(pointers) ++ [%{role: "type", target: {:entity, type, "instances"}}]
      }

      with {:ok, claims} <- Delta.validate(claims),
           {:ok, sig_hex} <- Keys.sign(claims, seed) do
        {:ok, {claims, sig_hex}}
      end
    end
  end

  # D14, mirroring Kyber.Events: floats only past the builder
  defp timestamp(ts) when is_integer(ts) do
    f = 1.0 * ts
    if trunc(f) == ts, do: {:ok, f}, else: {:error, {:not_exact_f64, :timestamp}}
  end

  defp timestamp(ts) when is_float(ts), do: {:ok, ts}
  defp timestamp(_), do: {:error, :timestamp_not_a_number}
end
