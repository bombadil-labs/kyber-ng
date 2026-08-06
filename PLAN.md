# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The Operator Surface — a CLI for the whole stack (escript)

**Objective:** Every loop so far delivered MODULE APIs. T8 gives the harness a FACE: a
`kyber` escript (stdlib Mix escript — zero new deps) driving the full stack:
`view`, `ingest <source.json>`, `render <vault_dir>`, `refresh <vault_dir>`,
`export`, `import <wire.jsonl>`, `migrate <legacy.jsonl>`. Tagged errors printed to
stderr with pinned exit codes (0 ok / 1 operational error — never a crash stacktrace);
store-down answers a clean message. The escript config is a ONE-TIME mix.exs stanza
(pinned: the mix.exs diff for T8 is EXACTLY the escript stanza — the rail amendment is
deliberate, additive, and zero-dependency). Every subcommand is exercised end-to-end
against a tmp store in tests (the subcommand dispatch is a pure-ish function tested
directly; the escript entrypoint is a thin wrapper).

**Requirements (contract: .adlc/specs/T8.md):**
1. `Kyber.CLI` — escript main_module: `main/1` parses argv → dispatches; each command
   returns `{status, message}` → `IO.puts` + `System.halt(code)`; every failure path is
   a tagged tuple printed as a clean one-liner, never a crash.
2. Subcommands (each with pinned flags): `view` (sorted claims, one per line — the
   harness's view), `ingest <file>` (the T4 source shape from a JSON file; keyring from
   `--keyring <dir>`), `render <dir>` / `refresh <dir>` (the vault), `export` /
   `import <file>` (federation), `migrate <legacy>` (the T6 archivist).
3. `mix escript.build` produces a working `kyber` binary; the mix.exs diff is pinned to
   the escript stanza alone.

**Success Criteria (the gate):**
- `mix test` green; `! grep -r "Process.sleep" test/`; `mix format --check-formatted` exits 0.
- `mix escript.build` + a smoke run of every subcommand against a tmp store (asserted
  exit codes + output shapes).
- A store-down subcommand prints the clean tagged message and exits non-zero.

**Out of scope (later loops):** the Discord transport (gated on substrate L4), federation
peers (network transport), legacy semantic interpretation, sqlite/packs backends, the
reactor/subscriptions, vault-to-store writes.

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
- **Loop 8 (T8, in flight)** — the operator surface: `kyber` escript CLI driving the
  whole stack (view/ingest/render/refresh/export/import/migrate; pinned exit codes;
  one-time mix.exs escript stanza).

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
