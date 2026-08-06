# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Durable Store

**Objective:** The store only learns — and it remembers across restarts. An append-only
JSONL wire log (the pinned envelope, one JSON text per line) behind the door: every append
verifies then merges AND persists; boot replays the log through the door (re-verify +
re-merge, the `admit/2` shape) so a reopened store is provably the same ground.

**Requirements:**
1. `Kyber.Log` — the append-only file: `open/1`, `append/1` (one wire-envelope JSON text per
   line), `stream/1` (lazy lines for replay). Torn-write tolerant: a partial final line is
   reported, never fatal. Nothing is ever rewritten or deleted (spec/04-persistence.md §2).
2. `Kyber.DurableStore` — the door on disk: `start_link(log_path)` replays the log through
   `Kyber.Store.admit/2` (re-verify every signature, re-merge by union) into the in-memory
   set; `append/1` = door + log write (verify → merge → persist, in that order); `set/0`
   for reads. Reuses `Kyber.Store`'s door machinery — no second verification path.
3. Replay integrity: a tampered line mid-log is refused and reported, never silently merged;
   a torn final line is tolerated and reported; duplicates are no-ops (union).
4. TDD; no Process.sleep; `mix format` clean.

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- A delta survives a restart: open → append → stop → reopen → the delta is present and its
  signature re-verifies (replay is re-verify + re-merge, AC-proven).
- A torn final line (simulated truncated write) is tolerated: earlier lines replay, the torn
  line is reported, the store serves.
- A tampered line mid-log is refused and reported; the store serves the honest remainder.
- Replay is order-independent: the same log lines in shuffled order converge to the same set
  (union — the CRDT stays honest on disk).

**Out of scope (later loops):** sqlite/packs backends, federation, the reactor, the Discord
plugin, migration, vault-as-view.

---

## 1. Current State (What Works)

- Founding spec landed (SPEC.md + spec/00–07); repo runs ADLC (`.adlc/` contract).
- **Loop 1 COMPLETE (T1, archived)** — the unified event layer: `Kyber.Keys` (0600 atomic
  keyring, KYBER_SEED import), `Kyber.Events` (five claim templates, exact §2 vocabulary,
  D14 float timestamps), `Kyber.DeltaSet` (grow-only union), `Kyber.Store` (the door:
  closed envelope → Profile parse → id recompute → D1 unsigned refusal → strict Ed25519 →
  union). 41 tests, 0 failures; loam-compat proof byte-identical through real JSON text;
  P1–P7 gates green, adversarial review 8/8 findings fixed.

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
