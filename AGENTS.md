# AGENTS.md — Operating Doctrine for Autonomous Coding Agents

*Read this before doing ANY work in this repo. [CLAUDE.md](CLAUDE.md) is the process (Ralph Loop,
hard limits, testing norms — binding). This file is HOW to actually work as an autonomous agent
here. Both claude-code and prime-agent read both files by default.*

## Write-first doctrine (the analysis-paralysis fix — proven 2026-08-06: 71 min → 211 s)

- Your reading list is capped at ONE file: the ticket/spec that defines this build. The
  substrate (SPEC.md, spec/) is for LOOKUP when you need a fact — never pre-read "to understand
  the system" before writing. Unbounded reading burns the budget with zero artifacts.
- Your FIRST tool action must be writing a FAILING test for AC1. Then red→green per AC, one AC
  at a time.
- Never more than 2 consecutive read-only turns. Every 3rd turn MUST modify a file or run the
  tests.
- The completion gate encodes DELIVERABLE EXISTENCE (`test -f` per named deliverable + the
  suite) — an early gate green before deliverables exist is NOT success; keep working until the
  deliverables exist and the suite passes.

## Pacing (the one-op-per-turn killer — proven: 105 turns × 40 s → 3.5 min)

- BATCH: write multiple files per turn when they belong together. Never serialize one operation
  per turn.
- Targeted tests during iteration (the test file you're working on). Full suite: at most once
  every 5 turns, plus once before finishing.
- Do NOT run `mix test` after every implementation step — that is how a build stalls.

## Model & harness notes (re-test in progress — 2026-08-06)

- kimi-k3: `--provider moonshotai --model kimi-k3` (DASH form; base api.moonshot.ai/v1; env
  `MOONSHOT_API_KEY`). The `moonshotai/Kimi-K3` SLASH form routes to the HuggingFace router —
  different endpoint, don't use it.
- **REVISED UNDERSTANDING**: the "`--thinking max` deadlock" and "deepseek-v4-flash drowns in
  big-build context" diagnoses from 2026-08-06 are SUSPECTED CONFOUNDED by the daemon idle-
  eviction sweep (same signature: `message_start` fires, then 10–30 min of nothing, worker CPU
  ~0.7% — NOT thinking). With `idleEvictionMinutes: "off"` persisted in `~/.prime/agent/
  settings.json`, do NOT assume either failure mode — verify empirically on the current build.
- The daemon must have `idleEvictionMinutes: "off"` and the API key in BOTH daemon and client
  env. Verify daemons by PROCESS (`pgrep -P <wrapper>`, key in `/proc/<pid>/environ`), never by
  socket file (stale sockets lie).

## Hard limits (from CLAUDE.md — binding, not negotiable)

- **rhizomatic is frozen/normative** — never edit deps/ from here.
- **The atom is not renegotiable**: content-derived identity, merge-is-union,
  retraction-is-negation. No internal dialect.
- **Ephemeral events are not deltas** (D5). **The store only learns** — nothing is deleted.
- **No `Process.sleep` in tests, ever** — `assert_receive/3`, `catch_exit`, or explicit state
  polling.
- Rails frozen: `deps/`, `spec/`, `SPEC.md`, `mix.exs`, `config/`. Never touch the real
  `~/.kyber` — tmp store/keyring everywhere.
- TDD: failing test first, verify it fails for the RIGHT reason, then implement.

## Reporting

When the build lands: report exactly what was built, what the tests prove, and ANY spec
contradiction found — the contradiction is the deliverable; record it, don't paper over it.
Never overwrite PLAN.md (Hermes owns it).
