# SPEC-0: The Unification — Architecture & the DNA Mapping

**Status:** Founding spec (design accepted; implementation begins Loop 1)
**Depends on:** SPEC.md

---

## 1. What Kyber Is

Kyber is an agent harness. It runs an LLM agent with a Discord gateway, cron, tools, voice, and an
Obsidian-native memory layer. The first kyber (bombadil-labs/kyber, born as `liet-codes/kyber-beam`)
built this on a homegrown event architecture:

```
Delta (id + ts + origin + kind + payload + parent_id)
  → append-only JSONL log
  → pure Reducer: (state, delta) → {new_state, effects}
  → Effect.Executor → plugins (LLM, Discord, cron, voice)
  → tool loop → new deltas back into the log
```

That architecture was the rhizome *before the format existed*: immutable events, pure reduction,
replayable history, and an explicit commitment to **Event-Driven Input Saturation** —
`message.received` does not call the LLM; it emits `prompt.submitted`, an annotator saturates it
into `prompt.annotated`, and *only then* does the inference trigger fire.

Rhizomatic formalized exactly this shape: deltas as the atom, evaluation as pure functions,
computation as authorship. This spec closes the loop — kyber's own architecture, retrofitted onto
the format it predated.

## 2. The Three Layers

| Layer | What it is | Lives where |
|---|---|---|
| **Harness** | Elixir/OTP: plugins (Discord, LLM, cron, voice), tools, supervision, dashboard. Everything that touches the world. | this repo (`lib/kyber/`) |
| **Events** | Every event is a signed rhizomatic claim. The delta log IS the memory. | this repo (`lib/kyber/events*`) |
| **Substrate** | Canonical CBOR, content addressing, Ed25519, packs — the atom, already proven. | `rhizomatic` repo, `implementations/elixir`, consumed as a git dep (§3) |

## 3. The DNA Mapping (old kyber → new kyber)

| Old kyber | New kyber | Why |
|---|---|---|
| `Delta{id: random 32-hex}` | `id = BLAKE3(canonical CBOR)` — content-derived | No instance mints identity (P6). Same facts, same id, everywhere. |
| `origin: {:channel, ch, cid, sid}` etc. | `claims.author` — an Ed25519 key | Sovereignty: provenance is cryptographic. A subagent is an author; a human is an author. SPEC-1 §2.2 removed the `system` UUID for exactly this. |
| `kind: "message.received"` | Roles/contexts on pointers; vocabulary as data | The reducer's pattern-match table becomes schemas (P3). Kinds are not hardcoded; they are claims about claims. |
| `payload: %{...}` | Pointers: EntityRef / DeltaRef / Primitive / Bytes | The relational structure stops being lost. One fact, many pointers. |
| `parent_id` | `rhizomatic.txn.prior` DeltaRef / Merkle reference | Causality becomes a signed claim, not a field. |
| JSONL log, append-only | Grow-only delta set; merge is union | Fork/merge/federation fall out of the atom (SPEC-1 §8). |
| `Reducer.reduce/3` (kind dispatch) | `eval(term, dset)` + `resolve(policy, hview)` | Deterministic, policy-folded, no side effects (P5). |
| `State` (an Agent) | Materialized views — content-addressed | State is assembled at query time; ordering is a property of reduction, not storage. |
| `Effect.Executor` | Subscriptions + the write-back loop (§5) | Side effects happen; their occurrence is itself recorded as a signed claim. |
| `{:subagent, parent_id}` | A derived author (SPEC-7): own key, budget, signed outputs | Multiplicity gets identity. |
| Event-Driven Input Saturation | Reactor subscriptions + derived authors | "Functions fire when their inputs condense" becomes infrastructure, not a hand-rolled chain. |

## 4. Design Decisions (decided, not open)

- **D1 — All kyber deltas are rhizomatic claims, signed.** No exceptions, no internal dialect. The
  store only ever holds wire-format claims. Byte-compatible with loam's door (`POST /:mount/append`).
- **D2 — Identity is content-derived.** Random ids are gone. Replays dedupe by construction.
- **D3 — Authorship is keyed.** The human is an author with their own key; the agent is an author;
  subagents are derived authors. (§2)
- **D4 — The vocabulary is namespaced.** Kyber semantics ride the `kyber.*` vocabulary; store
  participation uses loam's (`loam:store`, `loam.registration`, `loam.trust`) so a loam gateway can
  govern and serve the same ground. Roles and contexts are bare words at the atom; meaning is
  vocabulary (§1).
- **D5 — Ephemeral events are not deltas.** `cron.fired` heartbeats never reach the delta layer.
  The old broadcast-only hack (400K deltas in 42h) was a symptom of the wrong boundary. The store
  only learns facts; pulses stay OTP messages. (§4)
- **D6 — The vault is a materialized view.** The human-navigable Obsidian vault becomes a markdown
  lens over the delta set — the same human-readable space, but a view, not a second source of truth.
  Write a note → a signed claim; read a note → you are resolving a view. (Later loops.)
- **D7 — Effects are the write-back loop.** A plugin subscribes to a materialization, acts in the
  world, and records the act as a signed claim. Nothing real happens unrecorded; nothing recorded is
  unverifiable. (§5)
- **D8 — Substrate work lives in the substrate repo.** The evaluator and reactor in Elixir (L1/L4)
  are work in `implementations/elixir` of the rhizomatic repo, justified by this consumer. Kyber
  never forks the substrate. (§3)

## 5. Invariants

1. Every delta in a kyber store: id recomputes from claims; signature verifies (strict, SPEC-1 §5.1).
2. Merge is union — commutative, associative, idempotent. Ingestion order never changes state.
3. Nothing is deleted. Retraction is negation; erasure (if governed) is loam's operator-only act.
4. Evaluation is deterministic. Two readers see different truths only because they chose different
   lenses (P5).
5. Tests never `Process.sleep`. (Kyber operating convention, carried forward.)

**Provenance.** Founding — Hermes, 2026-08-06. The DNA mapping is the unification analysis of the
three bombadil repos; the design decisions resolve the tensions that analysis surfaced.
