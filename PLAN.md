# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: T16 — Incremental, federatable indexes over the append-only store

**THE LIABILITY → THE STRENGTH (user framing, 2026-08-12):** performance over an append-only
log is the single biggest thing to get wrong. The store only learns, so every query ("what
points at this message?", "is this turn answered?", "this hyperview's members") is currently a
full-scan — and the dedup path the judge already flagged is O(N³). T16 turns that liability
into the substrate's biggest strength: **indexes become first-class, spawnable, federatable
things.**

- **F1 — incremental dedup index (in-process).** `DurableStore` maintains a dedup index in its
  own GenServer state, updated exactly once per admitted delta at the `do_append` chokepoint
  (the store already serializes every append and owns `state.set`). `open_duplicate?/1` reads
  that index in O(1) instead of scanning — closes the round-5 O(N³) medium.
- **F2 — append feed / subscribe seam.** `DurableStore` broadcasts each admitted delta (id +
  parsed claims) to a set of subscriber pids, in commit order, only after the write-ahead
  commit lands (same ordering guarantee as the existing reactor `notify_reactor` pin-1 seam).
  This is the rhizomatic door: anything that wants a view of the log subscribes once and
  receives every delta — no polling `set/0`.
- **F3 — `IndexServer`, spawnable per container / per hyperview.** A generic GenServer that
  holds its own `DurableIndex` view, fed by the F2 feed. Spin up one per container, per
  hyperview, per differently-tuned query — each an isolated process maintaining its own derived
  map. The default dedup view is one such instance.
- **F4 — `DurableIndex` pure module.** The index *logic* (new / add_delta / answered? /
  by_pointer) is a pure, side-effect-free module reused by both the in-process store index (F1)
  and every spawned `IndexServer` (F3). This is the reusable unit the rhizome forks.

**FEDERATION / OVERFLOW (the strength, user vision 2026-08-12):** because the index is a
spawnable process fed by an append-broadcast, the same machinery federates *out* — a
deployment can spin up new `IndexServer`s on demand to offload indexing, and a `DurableStore`
canfederate its feed to *other* kyber instances (or to a **loam** instance as an overflow
index) — the append-only log's "only learns" property makes every index a downstream projection
that can lag, catch up by replay, and merge by union, never wrong. T16 builds the local
spawnable primitive + the feed; cross-instance federation and loam-overflow are the next
loops' consumers of this seam (recorded in §2 backlog).

**Why now:** PR #5 is merged (T15 / Wisp). The round-5 adversarial review passed the gate but
flagged the O(N³) dedup scan as scaling debt — a *symptom* of having no index layer at all.
Every future "what points at X?" question (memory seam T14c, always-on context T14h,
hyperviews) would reinvent the same scan. Building the index as a spawnable, federatable
primitive pays the dedup debt AND seeds the later slices' query substrate in one move.

**Success criteria (exact, testable):**
- (a) `mix test` green at baseline (631 tests, 1 known `trajectory_test` flake); `open_duplicate?/1`
  no longer calls `DurableStore.set/0` to answer (TDD: a test asserts the call-count / a store
  flag).
- (b) The T15c dedup contract is preserved exactly: recent-unanswered re-send collapses;
  answered re-ask allowed; stale failed-turn re-send allowed (round-3 + round-4 behavior intact).
- (c) `DurableStore.subscribe/1` delivers one `{:delta, id, claims}` cast per admitted delta, in
  commit order, never for a refused delta.
- (d) A spawned dedup `IndexServer` fed by the feed answers `answered?/1` identically to the
  in-process index, and re-seeds correctly from `DurableStore.set/0` after a store restart.
- (e) Indexes are append-only, union-merge derived state (add on admit, never mutate/remove;
  retraction is a delta the feed delivers and the index ignores/folds) — matches the "store only
  learns" atom.
- (f) No `Process.sleep`; `mix format --check-formatted` clean; rails (deps/, spec/, SPEC.md,
  mix.exs, config/) untouched; real `~/.kyber` never touched.

**Out of scope (later loops):** a general query DSL / pointer-graph query language; materialized
hyperviews beyond the dedup view (the spawnable server exists; only dedup ships as a consumer);
retraction-aware index folding beyond "ignore the negation delta"; cross-instance federation
and loam-overflow wiring (the F2 seam enables them; the wiring is a later loop).

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
- **Loops 11–14 COMPLETE (T11–T14, Oracle Arc) — the agent lives in it.** Three-way
  campaigns (fable / kimi-k3 / deepseek, blind taste tests, folds, ADLC ceremony),
  winners merged via `provisional/oracle` → `main`/PRs:
  - **T11 — real model:** `Kyber.Agent.LlmHandler` (OpenAI-compatible, Moonshot kimi-k3,
    stdlib `:httpc`/`:ssl`, zero new deps) becomes a gather handler; schema layer
    (T11a), inference chain (T11b), memory store (T11c). The harness eats a real LLM.
  - **T12 — the agent acts:** tool chain (typed schemas, allow-list/prompt/deny gate,
    bounded filesystem + shell + HTTP) through the ToolCall→ToolResult delta chain with
    crash-window idempotence intact.
  - **T13 — the agent remembers:** associative memory — a semantic WALK over the entity
    graph (pointer edges, not a scroll), no embedding service (determinism clause);
    GROOVE saturation + bounded SYNCHRONICITY recall.
  - **T14 — the agent runs (autonomous, the Class 4 Oracle seed):** event-driven waking,
    the agent initiates; slices a–j (reactor T14a, policy T14b, memory seam T14c, skills
    T14f, identity T14g, always-on context T14h, I/O channels T14i, loose ends T14j) +
    boundary enumeration T14d + carry closure T14e. Merged to `main` (T14 arc complete).
- **Loop 15 COMPLETE (T15, PR #5 merged) — Wisp, the isolated sibling.** `kyber daemon`
  stands up an isolated kyber agent on `/tmp/wisp/` (never `~/.kyber`), content-derived
  identity across reboots, peer listener :48080 for Liet federation. Model/persona
  configurable via `--model`/`--base-url`/`--api-key-env`/`--system_prompt`; pure-CLI I/O
  via `kyber ctl` over the channel-socket JSONL protocol. Triple-send dedup (T15c) —
  order-independent, retry-safe, recent-window-bounded. ADLC P5 adversarial review ran to
  `approve` (rounds 1–5) closing HIGH/MEDIUM findings (nil-fallback engine build, dedup
  window, system_prompt threading, retry-safe dedup, loud no-key boot warning).
- **Loop 16 IN PROGRESS (T16) — indexed, federatable substrate.** See §0. The next loop.

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
- **Loop 16 — Indexing substrate (MERGED — PR #8, 2026-08-13):** incremental +
  federatable indexes. The local spawnable `IndexServer` + append feed landed; the seam
  enables two follow-on consumers: (a) **cross-instance federation** — a `DurableStore`
  federates its append feed to *other* kyber instances that maintain their own indexes
  (offload indexing on demand); (b) **loam-overflow index** — federate the feed to a
  **loam** instance as an overflow/secondary index. The append-only "store only learns"
  property makes every index a downstream projection that can lag, catch up by replay,
  and merge by union, never wrong.
- **Loop 17 — Index seed governance (raised by Wisp, 2026-08-13 tire-kick):** what
  qualifies as a seed for a seeded `IndexServer` view, who can bless one, and how a
  seeded set can be challenged over time. Wisp's read: seeds are governance, and
  governance should be explicit (metadata on *why* a seed exists, so future agents can
  challenge it). Also flagged: replay/convergence for late-spawned blind views (can a
  blind view catch pre-spawn claims without a snapshot — `subscribe_seeded` answers
  this, needs a test).

## 3. Long-Term Vision: Rhizomatic Cognition

Kyber is not a tree; it is grass. The append-only delta log preserves *how* every connection was
made; memory is portable (a kyber store is a loam store); multiplicity is native (each agent,
human, and subagent a sovereign author); and the human and the agent collaborate in the same
topological space — the vault is a lens, the store is the ground.
