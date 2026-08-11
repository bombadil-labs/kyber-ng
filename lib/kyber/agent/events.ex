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

  @doc "`ConversationSummary` — a lens artifact covering elided turns."
  @spec conversation_summary(String.t(), number(), String.t(), String.t(), [String.t()]) ::
          {:ok, signed()} | {:error, term()}
  def conversation_summary(seed, ts, session_id, content, covers) do
    build(seed, ts, "ConversationSummary", [
      %{role: "sessionId", target: {:entity, session_id, "summaries"}},
      %{role: "content", target: {:string, content}},
      Enum.map(covers, &%{role: "covers", target: {:delta, &1, "summarized"}})
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
  `PromptAssembled` — the prompt-as-delta claim (T14c D1): the assembled
  prompt the model SAW, answered as a store delta. EXACTLY three pointers,
  `sessionId` FIRST (the kind-marker grammar — `"sessionId"` routes to no
  subscription and matches no lens; the two `requestRef` readers,
  `Engine.answered?/2` and the conversation lens, key on the FIRST role).
  `content` is the canonical JSON of the message list
  (`Kyber.Agent.Prompt.canonical/1`) — exactly what `LlmHandler.chat/3`
  receives. `ts` is the triggering `InferenceRequested` delta's
  `claims.timestamp`, never wall-clock; ONE claim per assembled prompt.
  """
  @spec prompt_assembled(String.t(), number(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def prompt_assembled(seed, ts, request_id, session_id, content) do
    build(seed, ts, "PromptAssembled", [
      %{role: "sessionId", target: {:entity, session_id, "prompts"}},
      %{role: "requestRef", target: {:delta, request_id, "prompted"}},
      %{role: "content", target: {:string, content}}
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
