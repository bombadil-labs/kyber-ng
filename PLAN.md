# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Harness Loop — gather → translate → sign → persist → view

**Objective:** The harness awakens. T1–T3 built the machinery (door, durable store, wire,
supervision) but nothing yet RUNS the loop it was built for — "a Discord message in, a
model response out" at the atom. T4 wires the loop: a source event in → a signed claim
persisted in the durable store → a materialized view out. The transport (Discord etc.) is
gated on the substrate L4 reactor; T4 builds the loop against an injectable SOURCE
interface with a fake source in tests — the plugin ticket later is a thin adapter.

**Requirements (contract: .adlc/specs/T4.md):**
1. `Kyber.Harness` — `ingest(source_event)` → `{:ok, id} | {:error, reason}`: translate the
   source event to a `message_received` claim (author = the human key's pubkey), sign with
   the human key, `Wire.encode`, `DurableStore.append`. Source events come through a
   callback/adapter interface (testable fake; real Discord transport = later ticket).
2. `Kyber.Harness.agent_event/1` (model response in → `message_sent`-family claim signed
   by the AGENT key) — the response half of the loop, same pipeline.
3. A VIEW: `Kyber.Harness.view/0` materializes the store's delta set as claims (the
   vault-as-view is a later lens; this is the plain claims view).
4. TDD; no Process.sleep; format clean. The full loop is asserted END-TO-END: ingest →
   claim in the store → supervised restart → still there (replay) → view shows it.

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- A fake source event ingests to a persisted, signature-verified claim; restart survives it.
- The agent_event half signs with the agent key (author = agent pubkey) and persists.
- The view materializes exactly the stored claims.
- Source interface injectable: a second fake source shape flows through unchanged.

**Out of scope (later loops):** the Discord transport/adapter (gated on substrate L4),
federation, migration, vault-as-view, sqlite/packs backends, the reactor/subscriptions.

---

## 1. Current State (What Works)

- Founding spec landed (SPEC.md + spec/00–07); repo runs ADLC (`.adlc/` contract).
- **Loop 1 COMPLETE (T1, archived)** — the unified event layer: `Kyber.Keys`, `Kyber.Events`
  (five claim templates, exact §2 vocabulary, D14 float timestamps), `Kyber.DeltaSet`
  (grow-only union), `Kyber.Store` (the door: closed envelope → Profile parse → id recompute
  → D1 unsigned refusal → strict Ed25519 → union). P1–P7 green; review 8/8 findings fixed.
- **Loop 2 COMPLETE (T2, archived)** — the durable store: `Kyber.Log` (append-only JSONL
  wire log, dumb serializer, non-string keys refused) + `Kyber.DurableStore` (THE running
  store: boot replay through the door with exhaustive per-line classification,
  write-ahead verify→persist→merge, `replay_report/0` with live `failed_appends`,
  lazy-open first boot). 66 tests; P1–P7 green; review 4/4 findings fixed.
- **Loop 3 COMPLETE (T3, archived)** — the harness core: `Kyber.Wire` (production
  serializer, TestWire-oracle byte-parity across all 7 target shapes, deep key refusal,
  decode symmetry) + `Kyber.Application` (supervision, mkdir-owned, :permanent, config/
  env overrides). 83 tests; P1–P7 green; review APPROVE + 3 lows + 1 discovered door
  crash (atom-keyed claims refused pre-parse) — all fixed.
- **Loop 4 (T4, in flight)** — the harness loop: gather → translate → sign → persist →
  view (`Kyber.Harness`, injectable source interface, fake source in tests).

## 2. Active Backlog

- **Loop 2 — Durable store:** JSONL wire log + replay (spec/04 §2), the door on disk.
- **Loop 3 — The Discord plugin on subscriptions:** ingest signs `message.received` as the human;
  outbound acts on `message.sent` (spec/05 §4). Gated on substrate L4 reactor or a provisional
  harness-side gather (spec/04 §6).
- **Loop 4 — Memory & the vault as a view:** consolidator reads the set, writes consolidated
  claims; Obsidian vault becomes a materialized view (D6, spec/00 §4).
- **Loop 5 — Federation:** pull/offer with a loam instance (spec/06).
- **Loop 6 — Migration:** old kyber `deltas.jsonl` → claims with lineage (spec/07).
- **Substrate track (rhizomatic repo):** Elixir evaluator (L1) + reactor (L4) — kyber is the
  consumer that justifies them (spec/03 §3, D8).

## 3. Long-Term Vision: Rhizomatic Cognition

Kyber is not a tree; it is grass. The append-only delta log preserves *how* every connection was
made; memory is portable (a kyber store is a loam store); multiplicity is native (each agent,
human, and subagent a sovereign author); and the human and the agent collaborate in the same
topological space — the vault is a lens, the store is the ground.
