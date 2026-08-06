# T10 — The Operational Harness: kyber daemon + Gather + the runtime agent loop

Rev 1 — fork of the shared T10 contract (T10-claude). Implements the SAME contract as
its sibling independently (the blind taste test); amendments to THIS file only.

## Why this loop exists (user direction, 2026-08-06)

"Everything so far is the claims substrate... the kyber aspect is the runtime loop:
event in → signed claim → action → memory, with an agent actually living in it.
Nobody has operated it yet." The gate is an OPERATIONAL RUN: Hermes boots the daemon
on a tmp store, feeds it an event via the CLI, and watches the loop close — claim
lands, handler fires, response claim persists, the vault grows — then kills and
re-boots to prove idempotence.

## The architectural model (the contract's spine — all pinned)

1. **Deltas ARE the events.** One kind of thing in motion: a signed delta. Whether a
   delta is MEMORY (persisted in the store, rendered in the vault, exchanged with
   peers) or a PULSE (fires handlers, never persisted) is decided by ADMISSION
   POLICY at the sink — a property of reduction, never of the object. The pulse bus
   carries signed deltas; the line is drawn by what constitutes memory.
2. **Admission knob: persist-everything default.** Every delta the door admits is
   persisted by default. The knob tunes specific shapes DOWN to pulse-only (a shape
   whose history stops earning its keep). No shape is dropped by default.
3. **The handler contract is `(delta[]) -> delta[]`** — a pure function of its
   accumulated input view, firing when its declared input shape is SATURATED. The
   T10 built-in loop is the degenerate single-delta case; the contract is written
   for composition (the reactor's future {inputs, function} is the same shape).
4. **The gather is container-shaped** — ad-hoc containers are the hyperview's type:
   each handler's accumulated input view IS a container (its own delta-set,
   resolvable, droppable after firing, promotable to memory). T10 implements the
   degenerate form (role-matched single-delta views) but the structure must be
   container-shaped: a handler declares its input shape; the gather accumulates
   matching deltas into the handler's view; the handler fires on saturation.
5. **The dispatch cursor is a lens with state.** Replay must never re-fire: the
   cursor persists across boots (see AC3) so a re-boot resumes exactly where the
   previous run stopped. Pulses fire exactly once by construction. The cursor is a
   derived reading, never a source of truth.

## Deliverables

- **`Kyber.Daemon`** — the long-lived process: boots the app against a configured
  store (`--log`), watches for new claims (a `send_after` TICKER — never
  `Process.sleep`), dispatches matching deltas to handlers, blocks, and shuts down
  cleanly on SIGTERM.
- **`Kyber.Gather`** — the provisional subscription registry: handlers subscribe by
  declared input shape (T10: by ROLE); the gather routes new deltas into matching
  handlers' views and fires saturated ones.
- **The runtime agent loop** — a built-in handler pair: `message.received` in →
  deterministic `message.sent` out (a pure response — see AC4).
- **CLI: `kyber daemon`** — bounded, T8/T9 discipline (pre-flight argv before boot,
  load → put_env → start, exit codes, no crash stacktraces).

## Acceptance criteria

- **AC1 — Daemon lifecycle:** `kyber daemon --log <path> --keyring <dir>` boots the
  app on `<path>` (T8 boot discipline; the daemon never touches the real `~/.kyber`
  store). A second `daemon` invocation on the SAME log → a clean one-liner refusal
  (exit 1, "daemon already running on <path>" — a pid/lock mechanism the daemon
  owns; a stale lock from a killed daemon must not brick re-boot: the lock carries
  the pid and a dead-pid check). SIGTERM → clean shutdown (the lock releases; the
  store is intact; the ticker stops; exit 0). The ticker is `send_after`-based —
  `grep -r "Process.sleep" test/` finds nothing.
- **AC2 — The daemon watches the log:** the ticker polls the store for claims newer
  than the dispatch cursor. New claims are routed to the gather; the cursor
  advances. A claim the daemon itself wrote (its own response claims, its own
  checkpoints) is NOT re-dispatched to the handler that produced it (no loops; a
  handler's own outputs are routed like any claim but a handler cannot be its own
  subscriber... the agent loop's `message.sent` output is a claim the 
  `message.received` handler does NOT match — role-based routing makes this
  structural).
- **AC3 — The dispatch cursor persists (re-boot idempotence):** after a kill +
  re-boot, the daemon resumes from the persisted cursor and does NOT re-fire
  handlers for claims already dispatched. The cursor is NOT in-memory-only. (The
  kyber-shaped mechanism: the daemon writes a `daemon.checkpoint` claim carrying its
  position — state as data; a sidecar file is an acceptable alternative but the
  checkpoint claim is the recommended shape. The cursor is derived, never a source
  of truth.) THE TEST: boot → ingest a `message.received` → the handler fires once
  (one `message.sent` persists) → SIGTERM → re-boot → wait two ticks → assert NO
  second `message.sent` and no re-fire of any kind.
- **AC4 — The runtime agent loop is deterministic:** the built-in handler subscribes
  to role `message` with the received flavor; on saturation it emits a
  `message.sent` claim: same entity... the response claim is a NEW claim with role
  `message`, flavor `sent`, pointer back to the received claim (origin = the
  received claim's id), content = the deterministic reply `ack <received-id>`
  (pin the exact reply text so the operational gate asserts it verbatim). The
  response is signed with the daemon's keyring (the door verifies it). The handler
  is a pure `(delta[]) -> delta[]` function: no IO, no boot, no side effects
  beyond returning the response delta.
- **AC5 — Two-channel intake, one object type:** the daemon consumes BOTH (a) the
  persisted log (new claims since the cursor — what the vault renders) and (b) live
  pulses (ephemeral deltas pushed by `Kyber.Gather.notify/1` — e.g. a `watcher.tick`
  pulse that fires a handler but is never persisted). BOTH are deltas by shape
  (signed, author/pointer/timestamp present — the door's verification applies to
  pulses too). The admission policy is the only difference: log claims admit by
  default; pulses are ephemeral unless a policy says otherwise. THE TEST: a
  `watcher.tick` pulse fires its subscriber (side effect visible — e.g. the
  subscriber emits a `message.sent` in response) while NO `watcher.tick` claim ever
  lands in the store.
- **AC6 — Admission knob:** the daemon's intake admits every door-valid claim to the
  store by default (persist-everything). A shape can be tuned to pulse-only (the
  knob is a daemon option or config — one mechanism shape tuned in the smoke to
  prove the knob turns). The knob never weakens the door: a malformed/unsigned
  claim is refused, not pulsed.
- **AC7 — The operational gate (the real verification, run by Hermes):** boot the
  daemon on a tmp store with a tmp keyring; `kyber ingest` a fixture event (a
  `message.received` claim) via the CLI; watch (bounded explicit polling — never
  sleep): the claim lands, the handler fires, a `message.sent` response persists,
  the vault renders the conversation (view/grow); SIGTERM; re-boot; two ticks; no
  re-fire; the vault still shows exactly one exchange. This run is recorded as the
  loop's acceptance evidence (the operational-run gate record), not just prose.
- **AC8 — CLI discipline (T8/T9 carry-over):** `kyber daemon` = the ONLY new
  command; pre-flight argv before any boot (a usage-error path never boots);
  `--log`/`--keyring` options; usage errors exit 2; operational one-liners exit 1;
  success paths exit 0; no crash stacktraces (print/2 catch-all idiom).

## Rails (frozen, both forks)

- The substrate (deps/rhizomatic/...) is frozen and normative; the atom is not
  renegotiable; every delta is a signed rhizomatic claim; the store only learns.
- spec/ and SPEC.md untouched; mix.exs gets at most the escript stanza already
  present (no new deps — the daemon is stdlib OTP: GenServer + :gen_tcp if needed).
- TDD: the failing test first; no Process.sleep in tests (assert_receive / explicit
  state polling); `mix format` clean; warnings-as-errors clean.
- The real `~/.kyber` store is NEVER touched by tests or the smoke.

## Verification

`mix test` green; `mix format --check-formatted`; `mix compile --warnings-as-errors`;
`grep -r "Process.sleep" test/` empty; the daemon smoke (`KYBER_SMOKE=1 ... --only
smoke`) exercises AC1/AC3/AC4/AC5 against a tmp store and leaves zero leaked
processes (the os_pid kill idiom — Port.close does not terminate
spawn_executable children); **and the AC7 operational run** (Hermes boots and
operates the harness for real — the loop's gate).
