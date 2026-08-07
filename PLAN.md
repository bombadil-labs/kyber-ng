# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: The agent actually lives in it — an LLM handler on the Gather (the harness eats a real model)

**ORACLE ARC (user mandate 2026-08-06, supersedes the T11 tail when it ships):** after T11c
merges to main (closing the T11 split), the arc continues on a PROVISIONAL BRANCH
(`provisional/oracle`) — NOT main. T12 → T13 → T14, drafted by Hermes, each a full three-way
campaign (fable / kimi-k3 / deepseek, blind taste test, folds, ADLC ceremony) with winners
merged into the provisional branch as they land:

- **T12 — the agent acts** (capabilities): the tool chain matures from the stub echo to a real
  executor — action registry with typed schemas, a permission gate (allow-list / prompt /
  deny), bounded filesystem + shell + HTTP actions, all through the existing
  ToolCall→ToolResult delta chain with crash-window idempotence intact.
- **T13 — the agent remembers** (memory-driven): the T11c memory store becomes the agent's
  operational memory — tool outcomes, trajectory retrieval, provenance-weighted recall, the
  agent writing memory entities it later reads.
- **T14 — the agent runs** (autonomous operation, the Class 4 Oracle seed): event-driven
  waking (prompts, watcher ticks, memory edits), the agent initiating rather than only
  responding. All gated: permission gates, human-edit priority, the repo doctrine. NO
  misaligned behavior — aligned capabilities only.

**END STATE:** an UNMERGED PR from `provisional/oracle` into main + a comprehensive report of
every design choice, verdict, and discovery. Hermes owns PLAN.md updates; milestones recorded
per completed stage.

---
*T11 tail (in progress — the last slice merges to main, then the arc above forks):*

**Objective (T10's own closing line + the Prime Intellect thesis the user surfaced 2026-08-06: the
harness elevates the baseline reasoning of *any* model plugged into it):** T10 landed the
operational harness — `kyber daemon` (ticker, pid-lock, SIGTERM-clean), `Kyber.Gather` (container
subscriptions), the persisted cursor (re-boot idempotent by construction), the admission knob, the
vault, and the DETERMINISTIC built-in loop (`message.received` → `ack <id>`). The harness is real;
the agent is a stub. T11 swaps the stub: a REAL model — Moonshot Kimi K3 (provider wiring already
proven: `moonshotai/kimi-k3`, `MOONSHOT_API_KEY`) — becomes a gather handler, so an actual LLM
lives in the loop: event in → signed claim → model action → response claim → memory (the claims
substrate IS the memory). The Discord transport later plugs in as just another handler.

**Sequencing (decomposition decided 2026-08-06 — the umbrella spec stays the architecture; the
tickets own AC slices):** T11a the schema layer (AC2/AC7 — the vocabulary first, everything else
writes against it) → T11b the inference chain (AC1/AC3/AC4/AC5/AC8/AC9 — the operational run with a
real model call is its gate; the context builder takes a MemoryPort seam, not a concrete memory
container) → T11c the memory store (AC6 — the expected-to-iterate piece gets its own lifecycle and
slots into the seam; A/B-swappable by design).

**Requirements (contract: .adlc/specs/T11.md — the full architecture: deltas-as-events,
entities-as-resolutions, primitives-ride/composites-point, actors-bound-to-containers, schemas-as-deltas,
memory-reified-to-markdown):**
1. `Kyber.Agent.LlmHandler` — an OpenAI-compatible client (Moonshot base
   `https://api.moonshot.ai/v1`, key from env `MOONSHOT_API_KEY`, model `kimi-k3`, zero new deps —
   stdlib `:httpc`/`:ssl` like the rest of the repo; NO external HTTP lib) that implements the
   gather handler contract `(delta[]) -> delta[]` with REAL (non-deterministic) content.
2. The delta vocabulary (all pinned in the genesis schema set): `SubmittedPrompt` embeds
   primitives (author-by-signature, timestamp, channel, prompt_text) + `sessionId`;
   `InferenceRequested` embeds primitives and POINTS to `conversationRef` + `memoryPointers[]`
   + `promptRef`; `ResponseDelta` points back to its request + the memory it used. No delta
   embeds the conversation history (composites point). Crash-window safety is the pointer
   guarantee: the store is immutable, so frozen pointers resolve identically on re-fire →
   content-address dedup drops replays (the T10 lesson, reapplied).
3. The intake takes DELTAS only — never resolved views. Entities (Prompt, Session, Memory)
   exist by being referenced; resolution = gather hyperview → hyperschema → schema, time-versioned.
4. Actors bound to containers: `Kyber.Agent.ContextBuilder` (session hyperview + window lens +
   memory injection → emits one thin `InferenceRequested` per prompt), `Kyber.Agent.Engine`
   (stateful: fires on requests, walks pointers, calls the model, emits `ResponseDelta` /
   `ToolCall` mid-turn; in-flight turn state rehydrates from the chain), `Kyber.Agent.Memory`
   (MemoryEntity resolution + markdown projector + edit watcher + L0/L1 tierer + trajectory
   retriever), `Kyber.Schema` (schema container actor + genesis schema deltas; validate at
   admission; codegen is derived convenience, never authority).
5. The memory store round-trips through markdown (an Obsidian vault = the L2 tier, human-editable):
   system memories derive from response deltas; HUMAN edits are observed by the watcher →
   diff → attested `MemoryEdited` delta (`source: :human_edit`, old+new) → canon re-resolves.
   Canon is a RESOLUTION, never a store; `provenance` (model|human|derived) weights retrieval
   (human-canon authoritative, never auto-consolidated). The memory container is swappable
   behind the same substrate (the A/B property). OpenViking's L0/L1/L2 tiering + filesystem-as-
   projection (viking://) is the reference shape; ours derives from the delta substrate, not a
   sidecar store.
6. Tool chains are cascades of linked deltas (Prompt → ToolCall → ToolResult → … → Response),
   emitted as they happen; rendering/visibility is a lens, not data.
7. The operational run (THE gate, Hermes-executed): boot the daemon on a tmp store/keyring with
   the LLM handler live; CLI ingest a `message.received` whose content is a real question; the
   context builder fires, the model answers, the answer persists as `message.sent` (agent-signed,
   non-deterministic); the vault renders the exchange; SIGTERM; re-boot; the exchange does NOT
   duplicate; the answer claim is still in the store. Bounded explicit polling, never
   `Process.sleep`.
8. A memory affordance proves itself: the handler's SECOND invocation is grounded in the FIRST
   exchange — the model sees its own prior `message.sent` claims (the store as memory) and answers
   a follow-up that REQUIRES that memory ("what did I just say?"). verify: the second answer
   references the first exchange's content.
9. No `Process.sleep`; rails (deps/, spec/, SPEC.md, mix.exs, config/) frozen; the real `~/.kyber`
   never touched; format clean; warnings-as-errors clean. verify: the T9/T10 gate suite.
10. Determinism harness: with the LLM path disabled (or a canned stub handler), the T10
    deterministic ack loop still works — the built-in loop is the fallback, not a casualty.
    verify: the T10 daemon/agent_loop tests stay green unchanged.

**Success criteria (exact, testable):** (a) `mix test` green including handler/engine/memory/schema
tests; (b) the operational run (AC4) passes with a REAL Moonshot call (recorded as the loop's
acceptance evidence); (c) the memory-grounding follow-up exchange passes; (d) re-boot idempotence
holds with the LLM handler (no duplicate exchange, crash-window test included); (e) the memory
store round-trips: system memory → markdown → human edit → `MemoryEdited` delta → re-resolved
canon with `provenance: human`; (f) schema validation at admission (well-formed admitted,
malformed refused, unknown admitted raw); (g) the T10 deterministic tests untouched.

**The architectural model (user design, 2026-08-06 — the harness as a closed loop;
refined the same day: deltas AS the events — one kind of thing in motion):** every
operation in the harness generates a delta and writes it to the intake. The
persisted/ephemeral split is NOT a type distinction — it is a property of REDUCTION:
deltas are the events that pass through the pulse, and whether a delta is memory
(admitted to the log — the vault, the store, the peer exchange) or a pulse
(side-effect carrier — fires handlers, dropped by default) is decided by ADMISSION
POLICY at each sink, never baked into the object. One object everywhere: the wire,
the intake, the pulse, the log, the vault, the peer exchange all speak the same
signed-delta language; a handler receives a delta whether it arrived live, was
replayed, or came over TCP (promotion of a pulse to memory is free — same object,
admission is a policy decision; the reject-never-repair door applies to the ephemeral
channel too). The pulse IS the log in motion; the log IS the pulse at rest — replay
and live delivery are the same mechanism, so the gather's dispatch cursor prevents
re-running side effects (handlers are pure functions of their inputs — re-delivery is
harmless by construction), never "re-firing events." D5 is re-read accordingly:
pulses are delta-SHAPED; "pulses never reach the delta layer" holds by admission
policy (role-based: memory-ish roles admit — message.*, session, insight; mechanism
roles pulse-and-drop — watcher.*, cron.*, handler.*), the door's verification is the
final gate, and the vault only renders the store so mechanism noise never reaches the
human. (The D5 re-read is a deliberate spec amendment, recorded when T10's contract
is written.)

**Admission default (user refinement, 2026-08-06): persist EVERYTHING first.** "Is it a
memory or not" is a KNOB, not a policy decided upfront: we start by persisting every
delta, and later demote shapes whose history no longer needs persisting (a
role/shape-based admission knob at the door — tune a shape to pulse-only when its
history stops earning its keep). The store only learns — you can always tune a shape
down, but you can never recover what you chose not to persist, so the default is
learning. The vault renders the store, so the human sees the full memory until the
knob tunes.

**The handler contract (user refinement, 2026-08-06): `(delta[]) -> delta[]`, not
`(delta) -> [delta]`.** The reactor/gather takes an input SET — many deltas, or deltas
pre-organized into a hyperview/view — and is PARTIALLY APPLIED incrementally as deltas
accumulate; it fires only when enough deltas have accumulated that its declared input
is SATURATED. A handler = {declared input shape, function} where the function maps an
accumulated input view to output deltas; saturation = the declared shape's required
slots are filled. The T10 built-in agent-loop handler is the degenerate case (a single
`message.received` saturates it), but the contract is written for composition: the
reactor's future {inputs, function} declaration and the gather's dispatch are the
same shape, so the L4 upgrade is a drop-in.

**Ad-hoc containers = the hyperview's type (user refinement, 2026-08-06 — the
synthesis of loam's container primitive and the gather):** the ideal abstraction to
"gather-into" is the container — loam's §27 primitive (its own delta-set, resolvable
in its own right, spawn/seed/resolve/ship/drop) IS the lifecycle of a handler's
accumulated input view. A handler's declared input shape compiles to a container's
MEMBERSHIP TERM — no new language. The contract: `{ inputs: [container_spec, ...],
function: (containers) -> [delta] }`; partial application = each incoming delta
routes into the containers whose membership it satisfies; SATURATION = the bound
container's membership is complete; the function fires when every bound argument is
saturated. Consequences: (a) content-addressing gives determinism — a saturated
container's identity derives from its contents, so a firing is reproducible and the
door dedups its outputs (idempotence stays structural, one level up); (b) the
ephemeral/persisted axis is POSTURE — a SHARED hyperview (live reading, dropped after
firing) is the pulse; a SEPARATE one (materialized bytes) is memory; the admission
knob tunes which containers a delta gathers into (persist-everything default = every
container separate until tuned shared); (c) PROMOTION is the one operation — a pulse
container worth remembering is materialized (same deltas, same identity, posture
flipped: the quarantine→blessed, ephemeral→memory, untrusted-peer→trusted arcs are
all the same move); (d) the reactor graph closes — firing outputs gather into
downstream containers, making the L4 reactor a router over one primitive. The vault
(T7) is retroactively validated: it WAS a shared container (membership =
memory-shaped deltas, resolved into markdown); the cap is a bounded-membership
container. T10 discipline: ad-hoc containers stay GATHER-INTERNAL (no curated
entity, no new claim vocabulary — their declaration lives in the handler spec);
promotion to a named loam.container (§27 vocabulary) is the later landing point,
after loam's container design settles — kyber never races the substrate, but the
gather is container-shaped on day one.

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
- **Loop 9 COMPLETE (T9, archived)** — federation peers: `Kyber.Peer` TCP listener
  (stdlib :gen_tcp) + send_wire client; wire text + blank-line framing; strip-then-
  join (two-claim pin imported=2); resource caps (1 MiB frame, 16-handler pool);
  `kyber serve`/`send` (taxonomy: unreachable/timeout/closed). 158 tests; P1–P7
  green; premortem 8/8 folded (off-by-one frame deadlock); review 4/4 killed
  (resource-exhaustion, failure-atomic smoke, crash-dump hygiene, error taxonomy).
- **Loop 10 (T10, next — user direction: the kyber aspect)** — the operational
  harness: `kyber daemon` + `Kyber.Gather` (provisional subscriptions) + the
  runtime agent loop (`message.received` → handler → `message.sent`); the gate is an
  OPERATIONAL run: boot the daemon, ingest live, watch the loop close and the vault
  grow; re-boot idempotent. The Gather is container-shaped per the model (ad-hoc
  containers, admission-policy default persist-everything, `(delta[]) -> delta[]`
  handler contract). **Launch notes: (a) RE-TRIAL PRIME-AGENT on T10** — the shared
  daemon's other-tab work is nearly done; prime-agent gets a genuine shot at this
  build (T-series brief, per the 2026-08-06 agreement) before defaulting to
  claude-code — its ARC-AGI-3-class model may generalize where Opus pattern-matches;
  (b) **cache-warm sessions** — no more cold-start `claude -p` per step where it
  matters: use `--continue`/`--resume <session>` for follow-up steps in a loop so the
  substrate context stays warm (user note 2026-08-06: cold starts forfeit caching).

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
