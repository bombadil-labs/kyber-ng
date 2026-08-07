# T11a — The Schema Layer (claude fork)

Rev 1 — fork of the shared T11a contract for the claude leg of the three-way blind taste test (harness-tuning rematch 2026-08-06). Same contract as its siblings; amendments to THIS file only.

## Post-verdict amendments (blind taste test, 2026-08-06 — merged winner)

The three-way verdict (Fable 5 judge, anonymized A/B/C): **A (this leg) won 23–21–19** —
flawless on the validate/refuse/raw/resolve core loop, the most idiomatic actor shape, the only
implementation that gets derived-struct staleness right. Per the judge's merge recipe — *"C's
encoding, A's mechanics, B's evidence"* — the following folds landed in the merged tree:

1. **C's substrate-native schema encoding** (the single best idea): schema deltas now use the
   substrate's normative envelope vocabulary — `rhizomatic.hyperschema.name`/`defines`/`alg`/
   `term` pointers with the term as hex of canonical CBOR (`Rhizomatic.Cbor`), instead of the
   home-grown `"role:kind"` dialect. The genesis wire envelopes are COMMITTED data
   (`lib/kyber/schema/genesis/wire/genesis.jsonl`, one envelope per line — the store's own JSONL
   form) with a byte-for-byte round-trip test; `alg` 0.0 is kyber's T11a shape algebra until the
   substrate's L1/L3 evaluator lands in Elixir.
2. **A's mechanics kept** (the win): pure `Compiler` + thin `Agent` shell, CLOSED validation
   (closure is what makes "no delta embeds the conversation history" a structural theorem),
   retraction-enforced evolution, stale-struct-falls-back-to-map resolution.
3. **Entity-resolution hyperschemas folded from C**: `kind: "hyperschema"` terms (schema+root)
   compile into the set; `Kyber.Schema.resolve_entity/2` answers the bounded `HyperView` gather
   over a `DeltaSet` (Session at `session:` roots, MemoryEntity at `memory:` roots) — the spine-2
   bridge.
4. **B's evidence posture folded**: the replay matrix (re-ingest no-op, late-arriving older
   version no-op, retracting a superseded id never kills the live entry), the self-host check,
   and the drift-proof cross-validation (each infra schema's field set is asserted EXACTLY equal
   to the real `Kyber.Events` emitter's role set).
5. **AC2 literal role names** (B proved they cost nothing): `sessionId`, `conversationRef`,
   `memoryPointers`, `promptRef`, `requestRef`, `memoryUsed`; `channel` rides as a string.
6. **Negation retraction** folded from C: a `negates` delta retracts a schema entry by content
   address (retraction-is-negation); supersession is replay-safe.

**Three-way wash, recorded as the T11b seam:** none of the three legs wired
`Kyber.Schema.validate/1` into `Kyber.Store`'s door — the slice's rails limited scope to
`lib/kyber/schema*` + `test/schema_test.exs`. The door/schema wiring (and emitter type
declarations) is T11b's first job; all three builds flagged it independently.

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
