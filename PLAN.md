# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: Migration — the legacy log becomes claims (spec/07)

**Objective:** The ORIGINAL mission lands: kyber's pre-rhizomatic delta log
(`deltas.jsonl` in the legacy repo — `%Kyber.Delta{id, ts, origin, kind, payload,
parent_id}` per line, Jason-encoded) is unified with rhizomatic/loam deltas. T5's
promise pays off: the legacy log is TRANSLATED to wire text (each legacy delta → a claim
signed by the ARCHIVIST — the agent key attests "this delta existed"; the legacy identity
lives in the claim's pointers) and fed through `Federation.import/1` — the SAME door,
the SAME dedup (re-migration is idempotent), the SAME reporting. No fabricated
signatures: the archivist signature is the harness vouching for its own history.

**Requirements (contract: .adlc/specs/T6.md):**
1. `Kyber.Migration.migrate/2` (legacy_path, keyring_dir) — lazy-read the legacy
   deltas.jsonl, translate each line to an archivist-signed wire envelope, import via
   `Federation.import/1`; returns a migration_report (import_report + legacy-side
   refusals). Store-down guard (T5 shape).
2. `Kyber.Migration.translate_line/1` — PURE: a legacy delta map → `{claims, sig}`
   (agent-key-signed, legacy identity in pointers); untranslatable → tagged refusal.
3. A byte-realistic fixture (the legacy `to_map` shape) + idempotency AC (migrate twice →
   all skipped).

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- A fixture legacy log migrates: claims in the store, archivist-signed, door-re-verifiable,
  idempotent on re-run.
- Malformed legacy lines are reported with line numbers, never fatal; valid lines still land.

**Out of scope (later loops):** legacy SEMANTIC interpretation (memory/insight kinds →
rich claims — later loops), the Discord transport (gated on substrate L4), federation
peers, vault-as-view, sqlite/packs backends, the reactor/subscriptions.

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
- **Loop 5 COMPLETE (T5, archived)** — federation: `Kyber.Federation` export/import
  (deterministic wire JSONL, door re-verification, dedup, import_report observable;
  total never-crash — every stateful call exit-protected). 108 tests; P1–P7 green;
  review 4/4 fixed (1 medium: bare-call crash class eliminated).
- **Loop 6 (T6, in flight)** — migration: `Kyber.Migration` legacy deltas.jsonl →
  archivist-signed claims → `Federation.import` (the original unification mission).

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
