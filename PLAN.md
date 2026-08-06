# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Harness Core — production wire + supervision tree

**Objective:** The running harness gets a real wire and a started door. T1 built the door,
T2 made it durable — but the only envelope serializer lives in test/support (TestWire) and
nothing boots the store at app start (mix.exs has no `mod:`). T3 closes both gaps; every
downstream loop (plugins, federation, migration) stands on it.

**Requirements (contract: .adlc/specs/T3.md):**
1. `Kyber.Wire` — the production envelope serializer (stdlib JSON; the witness has none):
   `envelope/1`, `encode/1` (tagged errors; non-string keys refused; NaN/Infinity
   unrepresentable — finiteness holds), `decode/1`, `claims_json/1`. Round-trip AC:
   encode→decode term-identical; envelope re-admits through `Kyber.Store.admit/2`.
2. `Kyber.Application` — the OTP app: Supervisor starting `Kyber.DurableStore` with
   `Application.get_env(:kyber, :log_path)` (default `~/.kyber/store.jsonl`, runtime
   artifact). mix.exs gains `mod:` (a deliberate scoped amendment — mix.exs leaves this
   ticket's rails; deps/ + spec/ + SPEC.md + PLAN.md stay frozen). `Kyber.Store`'s T1
   Agent is NOT started — DurableStore is THE running store (T2 topology pin).
3. TDD; no Process.sleep; format clean.

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- Wire round-trip: encode/decode of a signed `message_received` envelope is term-identical
  and re-admits via the door (AC2).
- The app boots a registered `Kyber.DurableStore` at the configured log path; an append
  persists and replays across a supervised restart (AC4).
- `Process.whereis(Kyber.Store)` is nil after boot — exactly one running store (AC5).
- `git diff main -- mix.exs` shows only the `mod:` addition; deps/ and spec/ untouched (AC6).

**Out of scope (later loops):** the Discord plugin, the reactor/subscriptions (gated on
substrate L4), federation, migration, vault-as-view, sqlite/packs backends.

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
- **Loop 3 (T3, in flight)** — the harness core: `Kyber.Wire` (production serializer) +
  `Kyber.Application` (supervision tree, mix.exs `mod:`, DurableStore at app start).

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
