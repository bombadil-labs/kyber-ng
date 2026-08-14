# Kyber-ng — How We Work

Kyber is an agent harness on rhizomatic ground. The design is in [SPEC.md](SPEC.md) and
[`spec/`](spec/); the plan is in [PLAN.md](PLAN.md) (Section 0 = the current Ralph Loop). Read
SPEC.md and spec/00-overview.md before writing code. This file is the **process**.

Autonomous agents (claude-code, prime-agent) working this repo: **[AGENTS.md](AGENTS.md) is the
operating doctrine** (write-first briefs, pacing, model notes) — read it before starting; it and
this file are both binding.

## The Ralph Loop

1. **Define** — PLAN.md §0 carries the requirements and exact testable success criteria for the
   *next* loop. Hermes owns it.
2. **Execute** — a coding agent (`prime-agent`) is launched, bounded to §0.
3. **Verify** — Hermes is the Review Gate: runs the tests, checks no `Process.sleep` fragility,
   confirms the architecture aligns with the spec.
4. **Update** — Hermes updates PLAN.md: clears the loop, defines the next one. The agent never
   overwrites the plan.

## Hard limits

- **rhizomatic is frozen/normative** (SPEC.md "Hard limits", spec/03). Never edit the witness from
  here; a substrate need is a PR to `bombadil-labs/rhizomatic` + a conversation with Myk.
- **The atom is not renegotiable.** Content-derived identity, merge-is-union, retraction-is-
  negation. No internal dialect: every delta is a signed rhizomatic claim (D1).
- **Ephemeral events are not deltas** (D5). `cron.fired` pulses never reach the delta layer.
- **The store only learns.** Nothing is deleted; the cap is a lens, never a store property.

## Testing norms (binding)

- Tests are written ALONGSIDE the implementation, one AC at a time — not as a
  strict red/green loop. The goal is a well-tested codebase (every AC has a
  test), not the ceremony. Write the test and the code together; run the
  suite when a chunk of work is done.
- **No `Process.sleep` in tests, ever.** Use `assert_receive/3`, `catch_exit`, or explicit state
  polling.
- Test the claims emitted and the state changed — verify effects, not just state.
- The loam-compatibility claim is tested: wire JSON round-trips through `Rhizomatic.Profile`
  byte-identically.

## Code style & scope

- Pure functions in `lib/`; the only file I/O in the event layer is `Kyber.Keys` (key material).
- Correctness over speed; boring at the atom. Follow the witness's idiom — tagged tuples, never
  coerced values; reject, never repair.
- Match the witness's conventions (see `Rhizomatic.*` modules) rather than re-deriving them.

## Reporting

When a loop's work lands: run `mix test`, confirm the gate, update nothing in PLAN.md (Hermes
does), and report exactly what was built, what the tests prove, and any spec contradiction found
(the contradiction is the deliverable — record it, don't paper over it).
