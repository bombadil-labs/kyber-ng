# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: Federation — the wire speaks to itself (export/import)

**Objective:** A claim born on one kyber-ng instance survives a journey to another,
byte-identical, re-verified by the witness on arrival. T1–T4 built the claim lifecycle
(emit → sign → persist → view); T5 builds the exchange — and the import machinery IS the
migration path (spec/07's legacy-log unification will reuse it). The substrate L4 reactor
gates the Discord/plugin side, not claim exchange: two stores exchanging wire JSONL is
testable right now with tmp paths.

**Requirements (contract: .adlc/specs/T5.md):**
1. `Kyber.Federation.export/0` — the store's delta set as wire JSONL text (one pinned
   envelope per line, `Wire.encode`, deterministic order), for transport/backup.
2. `Kyber.Federation.import/1` — wire JSONL text → stream each line through
   `Wire.decode` → `DurableStore.append` (the door re-verifies EVERY signature; union
   dedups; refused/torn lines are reported, never fatal — the T2 replay policy, reused).
3. `Kyber.Federation.import_report/0` → `%{imported: n, refused: [line_nos], skipped: n}`
   (a pinned observable, mirroring `replay_report`).
4. Cross-instance AC: instance A ingests (T4 Harness) → export → instance B imports →
   the claim re-verifies (door admit), is present, view-identical. Byte-identical round
   trip: export(A) imported into B exports byte-equal to A's export (union of the same
   claims).

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- A cross-instance round trip proves signature re-verification + dedup (import twice → one).
- Torn/refused lines in an import are reported, never fatal; valid lines still land.
- import_report shapes are pinned and asserted.

**Out of scope (later loops):** the Discord transport/adapter (gated on substrate L4),
migration of the LEGACY kyber log (spec/07 — reuses import/1), the reactor/subscriptions,
vault-as-view, sqlite/packs backends.

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
- **Loop 4 COMPLETE (T4, archived)** — the harness loop: `Kyber.Harness` (ingest/2
  human-signed, agent_event/2 agent-signed, view/0 sorted claims; store-down guard +
  closed source contract + total never-crash) + `Keys.load_human_seed` (no env fallback)
  + keyring_dir config. 99 tests; P1–P7 green; review 3/3 lows fixed (TOCTOU, non-binary
  pin, precedence pin).
- **Loop 5 (T5, in flight)** — federation: `Kyber.Federation` export/import (wire JSONL
  exchange, door re-verification, dedup, import_report observable).

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
