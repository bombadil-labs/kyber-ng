# T10 — The Operational Harness: kyber daemon + Gather + the runtime agent loop

Rev 1 — fork of the shared T10 contract (T10-fable). Implements the SAME contract as
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
  structural). verify: a test ingests a claim, asserts the handler fired and
  the cursor advanced, then ingests a second claim the daemon itself wrote and
  asserts it did NOT re-fire the producing handler.
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
  claim is refused, not pulsed. verify: a smoke test boots the daemon with
  one mechanism shape tuned to pulse-only, pushes that shape, and asserts the
  handler fired while no claim of that shape landed in the store; an unsigned
  claim is refused by the door and never pulses.
- **AC7 — The operational gate (the real verification, run by Hermes):** boot the
  daemon on a tmp store with a tmp keyring; `kyber ingest` a fixture event (a
  `message.received` claim) via the CLI; watch (bounded explicit polling — never
  sleep): the claim lands, the handler fires, a `message.sent` response persists,
  the vault renders the conversation (view/grow); SIGTERM; re-boot; two ticks; no
  re-fire; the vault still shows exactly one exchange. This run is recorded as the
  loop's acceptance evidence (the operational-run gate record), not just prose. verify: the AC7 run IS the
  verification — the recorded operational run (bounded explicit polling, never
  sleep), executed by Hermes against a tmp store/keyring, with the assertions
  above (land → fire → persist → vault → kill → re-boot → no re-fire).
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

## Rev 2 amendments (contradictions found during the build, folded — not papered over)

- **"Role `message`, flavor `received`/`sent`" has no carrier at the atom (AC2/AC4).**
  The atom has no kind field: a claim's event kind is its template's FIRST pointer
  role, and template order is part of the content address (SPEC-1 §2). Folded: the
  gather's subscription key IS the first-pointer role — `message.received` routes as
  `"received"`, the ack routes as `"sent"`, `daemon.checkpoint` as `"checkpoint"`.
  This also makes AC2's no-self-loop structural rather than policed: a handler's
  output kind differs from its subscribed kind by template, so a handler cannot be
  its own subscriber without changing the vocabulary.

- **AC1's `kyber daemon --log <path>` contradicts the T8 pinned grammar.** T8 pinned
  `--log` as a GLOBAL PREFIX ONLY (`kyber [--log <path>] <command>`; a post-command
  `--log` is a usage error, machine-checked in cli_test AC2). AC1 spells the flag
  after the command. Folded: for the `daemon` command alone, `--log` is admitted in
  either position — it remains the same BOOT flag (main/1's load → put_env → start
  override), merely spelled where AC1 pins it; both positions at once is ambiguous
  (usage, exit 2). Every other command keeps the T8 prefix-only rule. Two further
  pins fall out: `--log` is REQUIRED for `daemon` (there is no implicit
  default-store daemon), and `Kyber.Daemon` refuses to init when no `:log_path` is
  configured — "the daemon never touches the real `~/.kyber` store" is enforced
  structurally, not by convention.

- **The persist-everything spine contradicts D5's absolute.** SPEC.md's hard limit
  D5 says ephemeral events NEVER reach the delta layer, while this contract's spine
  says persisted-vs-pulse is admission policy with a persist-everything default and
  "no shape is dropped by default". Left unfolded, the daemon's own `watcher.tick`
  heartbeat would either flood the store (persist default) or violate "no shape
  dropped by default" (a shipped down-tuning). Folded: **admission policy is carried
  by the channel choice at the sink, never by the object** (one type: a signed,
  door-verified delta — AC5's requirement holds on both channels). The log channel
  and handler outputs are memory by default (persist-everything, nothing dropped);
  the pulse channel (`Gather.notify/1`, plus the daemon's own per-tick
  `watcher.tick` heartbeat) is ephemeral by construction — D5's mechanism pulses
  ride it and never reach the delta layer. The knob (`--pulse-only <role>`) tunes
  sink shapes DOWN onto the pulse channel; AC5's "pulses are ephemeral unless a
  policy says otherwise" names a possible up-tuning that is deliberately NOT
  shipped — the spine's "tune shapes DOWN, never up" wins.

- **AC4's determinism outranks clock honesty.** A response claiming `now` would make
  every re-fire a NEW claim (content-derived identity), so the AC3 crash window
  (killed between the ack persisting and the checkpoint landing) would duplicate the
  ack. Folded: the built-in response claims the RECEIVED claim's timestamp and
  derives its outgoing id (`message:ack:<received-id>`), making the handler a pure
  function of its view — a crash-window re-fire produces the byte-identical delta
  and the sink skips it by content address. The pinned reply text: exactly
  `ack <received-id>`, `<received-id>` = the received claim's id hex. A future LLM
  handler should claim `now`; the built-in ack trades that for idempotence.

- **AC6's "smoke test" runs stronger than smoke.** The knob proof (persist default /
  pulse-only tuning / unsigned refused on both paths) is an ALWAYS-RUN in-VM test
  (test/daemon_test.exs, AC6 trio) rather than an env-gated smoke; the escript
  smoke (test/daemon_smoke_test.exs) carries AC5's never-persists half against the
  live ticker (no `tick`-kind claim in the store after real ticking). Coverage is
  split, not reduced.

- **Cursor mechanics, pinned as built (the recommended shape adopted).** The cursor
  counts consumed log lines; after any tick that dispatched a non-checkpoint claim
  the daemon emits `daemon.checkpoint` (`checkpoint`/`position` pointers, position
  as float per D14). Checkpoint-only ticks write no checkpoint — the mechanism
  converges (two checkpoints per exchange) instead of checkpointing its own
  checkpoints forever. A torn line at the log TAIL is held for the next tick (it
  may be a concurrent `kyber ingest` still writing), while a torn mid-log line is
  reported and skipped — the replay classification, applied live.

- **AC7 friction note (the operational recipe).** `kyber ingest` signs with the
  HUMAN key and T8 pinned that no seed-import CLI command exists, so the tmp
  keyring for the gate run is seeded once with:
  `mix run --no-start -e 'Kyber.Keys.import_human_seed(String.duplicate("cd", 32), "/tmp/t10-keyring") |> IO.inspect()'`
  (`--no-start` — nothing boots, the real store is untouched). The daemon needs no
  such step: a missing agent seed is minted on first boot (first boot IS the mint).

- **The store is multi-process — the log is a concurrent-writer file (post-verdict,
  from the sibling review).** The contract's phrasing ("the daemon tails the
  store's new claims") reads single-process, but the store is a shared JSONL log
  written by the daemon VM AND by separate `kyber ingest` CLI VMs (AC7 is
  precisely this). Folded: the daemon treats the log as an append-only file with
  concurrent writers — each tick re-reads from its cursor (no open-stream
  assumptions), a torn line at the TAIL is held for the next tick (an ingest
  VM's append may still be in flight — consuming it would skip the completed
  claim forever), and a torn MID-log line is reported and skipped (replay
  classification, applied live). The cross-VM shape is machine-checked: the
  smoke ingests via a SEPARATE OS process against the live daemon.

- **The pid-lock is taken with an atomic O_EXCL create (post-verdict fold).** The
  first-built read-then-write lock (`File.read` then overwrite) had a TOCTOU
  window: two racing daemons could both read "stale" and both boot. Folded: the
  lock's exists-check and create are ONE atomic operation
  (`File.open(lock, [:write, :exclusive, :binary])`); a held lock is reclaimed
  only when its pid is provably dead (`ps -p` — EPERM-safe, bounded attempts), so
  a force-killed daemon (lock survives, `terminate/2` never ran) never bricks
  re-boot. Machine-checked in the smoke: the refusal path, and a kill -9 phase
  proving the stale lock is re-taken with the new daemon's pid.
