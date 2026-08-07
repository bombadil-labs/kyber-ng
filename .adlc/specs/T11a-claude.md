# T11a — The Schema Layer (claude fork)

Rev 1 — fork of the shared T11a contract for the claude leg of the three-way blind taste test (harness-tuning rematch 2026-08-06). Same contract as its siblings; amendments to THIS file only.

Rev 1 — slice spec of the T11 umbrella contract (`.adlc/specs/T11.md`; spine pins 1, 2, 3, 7 —
deltas-as-events, entities-as-resolutions, intake-takes-deltas, schemas-are-deltas).

## Why this slice exists (design decision 2026-08-06)

"Nothing anywhere should have any confusion about the exact shape of the deltas it's reading or
writing." Everything else in T11 (the inference chain, the memory store) writes against the
vocabulary this slice pins — so it lands FIRST. The schema container is the resolution authority:
`validate/1` at admission (strict for declared lifecycle types, raw admission for unknown),
`resolve/1` for typed access. Schemas are themselves deltas: signed, content-addressed, versioned,
retractable — evolution is retraction-plus-new-issue, never a migration.

## Deliverables

- **`Kyber.Schema`** — the schema container actor: holds the compiled schema set in memory,
  subscribes to schema deltas (live evolution — a new schema claim recompiles the relevant entry
  without restart), answers `validate/1` and `resolve/1` (typed objects; handlers never spelunk
  roles by string).
- **The genesis schema deltas** — committed data (`lib/kyber/schema/genesis/`): hyperschemas +
  schemas saturating the lifecycle — `Session`, `SubmittedPrompt`, `InferenceRequested`,
  `ResponseDelta`, `ToolCall`, `ToolResult`, `ConversationSummary`, `MemoryEntity`,
  `MemoryEdited`, plus the T10 infra types. The vocabulary is pinned HERE: primitives ride
  (embed small facts of the act), composites point (references only — no delta embeds the
  conversation history).
- **Codegen** — Elixir structs generated from the genesis schema deltas are DERIVED convenience,
  never the authority; the runtime authority stays in the store.

## Acceptance criteria

- **AC2 — The delta vocabulary is pinned (primitives ride, composites point):**
  `SubmittedPrompt` embeds {author-by-signature, timestamp, channel, prompt_text} and carries
  `sessionId`; `InferenceRequested` embeds primitives and points to `conversationRef` (session
  root/head) + `memoryPointers[]` + `promptRef`; `ResponseDelta` points back to its request +
  the memory claims it used. No delta embeds the conversation history. verify: a schema test
  asserts each lifecycle delta validates against its genesis schema and that no
  `InferenceRequested` in the test fixtures contains conversation text (pointers only).
- **AC7 — The schema layer is deltas, validated at admission:** the genesis schema deltas
  saturate the lifecycle; the door validates every delta that DECLARES a known lifecycle type
  against its schema (ill-shaped → refused; reject, never repair); unknown types are admitted
  raw and never saturate typed handlers; `Kyber.Schema.resolve/1` returns typed objects.
  verify: a test ingests a well-shaped `SubmittedPrompt` (admitted), a malformed one
  (refused), and an unknown-type claim (admitted raw, no typed handler fires).
- **AC10 — Gates:** no `Process.sleep` in test/; rails (deps/, spec/, SPEC.md, mix.exs,
  config/) frozen; the real `~/.kyber` never touched; format clean; warnings-as-errors clean.
  verify: `grep -r "Process.sleep" test/` empty; rails-guard passes; `mix format
  --check-formatted` clean; `mix compile --force --warnings-as-errors` clean.
