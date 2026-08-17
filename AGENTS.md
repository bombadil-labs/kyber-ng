# AGENTS.md — Operating Doctrine for Autonomous Coding Agents

*Read this before doing ANY work in this repo. [CLAUDE.md](CLAUDE.md) is the process (Ralph Loop,
hard limits, testing norms — binding). This file is HOW to actually work as an autonomous agent
here. Both claude-code and prime-agent read both files by default.*

## Pacing (the one-op-per-turn killer — proven: 105 turns × 40 s → 3.5 min)

- BATCH: write multiple files per turn when they belong together. Never serialize one operation
  per turn.
- Targeted tests during iteration (the test file you're working on). Full suite: at most once
  every 5 turns, plus once before finishing.
- Do NOT run `mix test` after every implementation step — that is how a build stalls.

## Model & harness notes

- kimi-k3: `--provider moonshotai --model kimi-k3` (DASH form; base api.moonshot.ai/v1; env
  `MOONSHOT_API_KEY`). The `moonshotai/Kimi-K3` SLASH form routes to the HuggingFace router —
  different endpoint, don't use it. `--thinking max` is viable; expect slower per-turn
  cadence (heavy reasoning between tool calls is the mode working, not a hang).
- deepseek: use the BARE model id `--model deepseek-v4-flash` — the API rejects versioned
  ids like `deepseek-v4-flash-0731` (the settings.json defaultModel suffix; a 400 with "The
  supported API model names are ..." is the tell). Model-id problem, not a harness problem.
- The daemon must have `idleEvictionMinutes: "off"` (the idle-eviction sweep stalls
  in-flight API streams) and the API key in BOTH daemon and client env. Verify daemons by
  PROCESS (`pgrep -P <wrapper>`, key in `/proc/<pid>/environ`), never by socket file (stale
  sockets lie).

## Hard limits (from CLAUDE.md — binding, not negotiable)

- **rhizomatic is frozen/normative** — never edit deps/ from here.
- **The atom is not renegotiable**: content-derived identity, merge-is-union,
  retraction-is-negation. No internal dialect.
- **Ephemeral events are not deltas** (D5). **The store only learns** — nothing is deleted.
- **No `Process.sleep` in tests, ever** — `assert_receive/3`, `catch_exit`, or explicit state
  polling.
- Rails frozen: `deps/`, `spec/`, `SPEC.md`, `mix.exs`, `config/`. Never touch the real
  `~/.kyber` — tmp store/keyring everywhere.
- **Dashboard exception (Loop 19, user decision 2026-08-14):** the in-repo Phoenix
  dashboard track may amend `mix.exs`/`config/` and add Phoenix/LiveView deps under
  `deps/` — scoped to the dashboard feature; the substrate rails above stay frozen
  for everything else.
- Tests are written ALONGSIDE the implementation (every AC has a test), not
  as a strict red/green loop — well-tested codebase over ceremony.

## Reporting

When the build lands: report exactly what was built, what the tests prove, and ANY spec
contradiction found — the contradiction is the deliverable; record it, don't paper over it.
Never overwrite PLAN.md (Hermes owns it).
