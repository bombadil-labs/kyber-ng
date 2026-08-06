# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Vault-as-View — claims become a human-navigable memory (the lens)

**Objective:** The harness's human-facing memory. Legacy kyber's core value was "Memory
isn't a database schema; it's a markdown file a human can read and edit in Obsidian."
Kyber-ng's answer: the claims store is the truth, and the vault is a LENS over it —
`Kyber.Vault` materializes the store's claims as an Obsidian-compatible markdown vault
(one file per claim, `claim:<id>.md`, YAML frontmatter with author/timestamp/pointers,
body = the content pointer), deterministically rendered, idempotently refreshed (a
re-render never duplicates or orphans files — the cap is a lens, never a store property).
Nothing is deleted from the store; the vault is derived state that can be rebuilt from
claims alone (a full re-render of the same store yields byte-identical files).

**Requirements (contract: .adlc/specs/T7.md):**
1. `Kyber.Vault.render/1` (vault_dir) — claims → markdown files; store-down guard (T5
   shape); deterministic (same store → byte-identical files, sorted, no timestamps in
   content); frontmatter pinned (id, author, timestamp, pointers, role).
2. `Kyber.Vault.refresh/1` — idempotent: re-render of the same store leaves every file
   byte-identical (no churn, no duplicates, no orphans); a claim removed from the store
   (impossible — the store only learns) or a foreign file in the vault dir is left
   untouched (the lens never deletes).
3. Obsidian compatibility: `.md` files with YAML frontmatter, `[[wikilinks]]` between
   claims that reference each other (the entity pointers), readable by Obsidian.

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- Render → refresh: byte-identical files, zero churn; the vault rebuilds identically from
  a cold store replay.
- The store-down case answers a tagged tuple, never a crash.

**Out of scope (later loops):** the Discord transport (gated on substrate L4), federation
peers, legacy semantic interpretation, sqlite/packs backends, the reactor/subscriptions.

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
- **Loop 6 COMPLETE (T6, archived — THE ORIGINAL MISSION)** — migration: `Kyber.Migration`
  legacy deltas.jsonl → archivist-signed claims → `Federation.import` (unified with
  rhizomatic/loam deltas; value-type validation — no fabricated attestations). 123 tests;
  P1–P7 green; hollow-test 12 killed (strongest of the campaign); review 3/3 fixed.
- **Loop 7 (T7, in flight)** — the vault-as-view: `Kyber.Vault` claims → Obsidian
  markdown (deterministic render, idempotent refresh, wikilinks; the cap is a lens).

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
