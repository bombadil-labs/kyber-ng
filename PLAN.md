# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Unified Event Layer

**Objective:** Prove the unification at the atom. A kyber event — a Discord message in, a model
response out — is now a signed rhizomatic claim, byte-compatible with loam, in a grow-only set
whose merge is union.

**Requirements:**
1. `Kyber.Keys` — the keyring: agent seed mint/load (0600, never printed, `KYBER_SEED` import),
   human key import, `author_for_seed/1` → `"ed25519:…"`, signing via the witness's
   `Rhizomatic.Signer`. File I/O confined to this module.
2. `Kyber.Events` — claim templates for the core events per spec/01-events.md §2:
   `message_received/…`, `prompt_annotated/…`, `llm_response/…`, `message_sent/…`, `tool_exec/…`.
   Each builds the SPEC-1 pointer structure and signs with the right key (human-origin → human
   key; agent-origin → agent key).
3. `Kyber.DeltaSet` — grow-only set: `merge/2`, `member?/2`, `size/1`. Union semantics.
4. `Kyber.Store` — the door (spec/04-persistence.md §3): parse (JSON debug profile) → recompute
   id → strict signature verify → merge. Refuses tampered ids and wrong-key signatures.
5. Tests prove the loam-compatibility claim: the wire JSON of a kyber event round-trips through
   `Rhizomatic.Profile` byte-identically.

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/` (no sleep fragility, ever).
- Every emitted delta: `id` recomputes from canonical bytes via the witness; signature verifies
  via the witness's strict Ed25519.
- `message_received` signed by the human's key; `llm_response`/`message_sent` signed by the
  agent's key.
- `DeltaSet.merge` commutative + idempotent on a 3-delta fixture (assert both orders converge).
- The door rejects: (a) a delta whose id does not match its claims, (b) a signature by the wrong
  key.
- The wire JSON of a signed `message_received` parses via `Rhizomatic.Profile` and re-serializes
  to identical canonical bytes.

**Out of scope (later loops):** reactor/subscriptions (gated on substrate L4), Discord plugin,
persistence to disk, federation, vault-as-view.

---

## 1. Current State (What Works)

- Repo initialized; founding spec landed (SPEC.md + spec/00–07).
- Rhizomatic Elixir witness consumed as a git dep (spec/03-substrate.md) — Level 0: canonical
  CBOR, content addressing, strict Ed25519, packs.
- Loop 1 (above) is the first code.

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
