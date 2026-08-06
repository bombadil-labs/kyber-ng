# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Operational Harness — kyber becomes something you can run and live in (the daemon)

**Objective (user direction 2026-08-06: "I don't see the kyber aspects yet — get an
operational harness sooner than later that you can invoke and test against"):** T1–T9
built the claims substrate (door, store, wire, events, federation, migration, vault,
CLI, peers). The kyber aspect is the RUNTIME LOOP: event in → signed claim → action →
memory, with an agent actually operating it. T10 makes kyber runnable: a `kyber daemon`
(long-lived; boots the app; watches the log for new claims via a send_after ticker —
NEVER Process.sleep; dispatches each claim to registered handlers; blocks in a
receive-forever) + `Kyber.Gather` (the provisional harness-side subscription registry,
spec/04 §6 — handlers register for claim shapes by role/pointer target) + the agent
loop proven at RUNTIME (a built-in handler pair: `message.received` in → response →
`message.sent` out). THE acceptance test is operational: I (Hermes, the delegated
primary user) BOOT the daemon on a tmp store, ingest a real event through the CLI, and
watch the claim land, the handler fire, and the vault grow — the loop closing
end-to-end, live, not in a unit test. The Discord transport later plugs in as just
another handler (the deployment, unblocked without the substrate L4 reactor).

**Requirements (contract: .adlc/specs/T10.md):**
1. `Kyber.Gather` — a subscription registry: `subscribe(handler, matcher)` /
   `notify(claim)`; handlers match claims by role/pointer shape; the daemon's tailer
   routes each new claim through the registry.
2. `kyber daemon` — the long-lived loop: boot (T8 discipline), tail the store log
   (send_after ticks; never a sleep), dispatch claims to matching handlers, block
   forever; clean shutdown on SIGTERM.
3. The built-in agent-loop handlers: `message.received` → a response handler emits a
   `message.sent` claim (the T4 harness loop at runtime); the response is
   deterministic (pinned response text) so the operational test is byte-exact.
4. The operational test (THE gate): boot the daemon on a fresh tmp store → CLI ingest
   of a fixture source → assert the received claim lands → assert the sent claim lands
   (the handler fired) → assert the vault renders both → stop the daemon → re-boot →
   the loop continues (replay-idempotent: the already-handled claim is not re-fired).

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- THE operational run (the gate's verification, executed by Hermes): the daemon boots,
  the loop closes live, the memory grows, and the vault shows it.
- Re-boot idempotence: the daemon survives restarts without re-firing handled claims
  (the store only learns; the gather is a lens over the log, never a source of truth).

**Out of scope (later loops):** the substrate L4 reactor (the gather is the
provisional harness-side mechanism, spec/04 §6), the Discord transport (a handler
plugged into the daemon — the deployment), peer auth/TLS, legacy semantic
interpretation, vault-to-store writes.

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
- **Loop 7 COMPLETE (T7, archived)** — the vault-as-view: `Kyber.Vault` claims →
  Obsidian markdown (byte-exact golden literal, compare-then-write zero churn,
  resolving delta wikilinks, overwritten observable; NTFS-safe filenames). 132 tests;
  P1–P7 green; hollow 4 killed; review 3/3 fixed (2 medium: golden tautology,
  absent-ref resolution).
- **Loop 8 COMPLETE (T8, archived)** — the operator surface: `kyber` escript CLI
  (pure run/1, boot-ownership load->put_env->start, pre-flight never-boot pins,
  committed KYBER_SMOKE=1 smoke artifact). 142 tests; P1–P7 green; review 4/4 fixed
  (2 medium: boot-before-validation, unpinned boot sequence).
- **Loop 9 (T9, in flight)** — federation peers: `Kyber.Peer` TCP listener (stdlib
  :gen_tcp) + send_wire client; the wire text + blank-line framing; `kyber serve` /
  `kyber send`.
- **Loop 10 (T10, next — user direction: the kyber aspect)** — the operational
  harness: `kyber daemon` + `Kyber.Gather` (provisional subscriptions) + the
  runtime agent loop (`message.received` → handler → `message.sent`); the gate is an
  OPERATIONAL run: boot the daemon, ingest live, watch the loop close and the vault
  grow; re-boot idempotent.

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
