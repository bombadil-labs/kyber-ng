# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: Federation Peers — the wire speaks to itself over the network (TCP)

**Objective:** T5 made the wire portable (export/import). T8 gave the operator a CLI.
T9 makes federation REAL: two kyber instances exchange claims over the network. A
`Kyber.Peer` listener (stdlib `:gen_tcp` — ZERO new deps) serves the federation wire;
a client connects, sends the export text, the peer imports it through the SAME door.
The framing is the wire text itself + a single blank-line terminator (the T5 import
already treats the final empty segment as the delimiter — the protocol is the format).
The trust model IS the claims: the door verifies every signature; a peer can only ADD
(signed, content-addressed) claims — the store only learns; garbage input is refused
per line, never a crash. `kyber serve [--port N]` + `kyber send <host> <port>` extend
the CLI (lib/ scope). Store-down answers a clean refusal line, never a crash.

**Requirements (contract: .adlc/specs/T9.md):**
1. `Kyber.Peer` — a supervised listener: `start_link(port: p)` (port 0 → ephemeral),
   accepts connections, reads the framed wire text, `Federation.import/1`s it, replies
   with a status line (`ok <imported>/<skipped>` or a tagged refusal); a client
   disconnect mid-frame never crashes the listener; garbage input → refused lines.
2. `Kyber.Peer.send_wire(host, port, text)` (or the client half) — connects, sends the
   export text + the blank-line terminator, reads the status line.
3. CLI: `kyber serve --port N` (foreground listener; prints the bound address) and
   `kyber send <host> <port>` (exports + sends + prints the peer's status).

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- A live exchange: peer A exports → sends to peer B (ephemeral port) → B imports →
  both stores hold the claim; re-send → all skipped (dedup across the network).
- The peer survives: garbage lines refused with line numbers, a dropped connection
  mid-frame is a non-event, store-down answers the refusal line.

**Out of scope (later loops):** the Discord transport (gated on substrate L4), auth/TLS
for peers (the claims ARE the trust; transport encryption is a later concern), legacy
semantic interpretation, sqlite/packs backends, the reactor/subscriptions.

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
