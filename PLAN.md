# Kyber-ng Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and
the long-term vision. Section 0 defines the NEXT Ralph Loop — requirements and exact testable
success criteria. Hermes owns updating this file; the coding agent does not overwrite it.*

---

## 0. Next Ralph Loop: T17 — Agent identity as a delta-folded entity (spin up an agent by name)

**THE GAP:** T15 proved the daemon mechanics but every agent boot is a bag of
CLI flags (`--model`, `--base-url`, `--api-key-env`, `--operator-seed-env`,
`--oracle-seed`, `--system-prompt`, `--channel-socket`, `--loop`, `--keyring`,
`--log`) — nothing about *who the agent is* survives between boots. T17 makes
**an agent an entity folded over its own delta stream** (the house doctrine:
deltas SET properties, facts merge, values supersede, retraction is negation).
The agent's operational identity (soul, provider, model, key env, prompts,
seed policy) lives as `AgentSet` deltas in the agent's own store. **No reified
config file** — the delta stream is the ONLY source of truth; every mutation
goes through a delta-generating interface; config is **hot-swappable** (a
delta takes effect on the next inference cycle); an **automatic retraction
harness** (last-known-good, per-field, bounded) is the safety net; secrets are
env-referenced or encrypted-at-rest and never ride the prompt.

**Contract:** `.adlc/specs/T17.md` — 24 ACs, premortem-folded (fable-5, 9
causes), spec-lint 24/24 verified. The spec IS the source of truth for this
loop; §0 summarizes the shape and the gates.

- **F1 — `AgentSet` delta + fold.** New declaration delta (mirrors
  `ProfileSet`): `events.agent_set/…` builder, hyperschema/genesis
  registration, `Kyber.Agent.Config.resolve/2` fold (per-field last-set-wins,
  retraction step-back, prospective self_config grant, semantics-aware dedup).
- **F2 — Boot by name.** `kyber agent new/list/show/set/unset/retract/rekey`
  (`:no_boot` class) + `--agent <name>` on `daemon`/`discord`; registry
  pointer `~/.kyber/agents/<name>`; genesis default layer (deepseek) validated
  at new-time; boot mints `identity:soul` idempotently.
- **F3 — Hot-swap.** Daemon subscribes (T16 feed) to `AgentSet` deltas;
  rederives on the next inference cycle; CLI overrides pinned + re-applied
  after every re-fold; `status` shows fold-vs-live.
- **F4 — Safety harness.** Per-field retraction on config-class failure
  (explicit classifier: 400/401/404/missing-env/bind/decrypt = config-class;
  429/5xx/timeout = transient, never retract); bounded step-back; terminal =
  engine deepseek defaults; `ConfigRollback` claim + notification.
- **F5 — Secrets.** Env-name reference OR encrypted-at-rest (`{enc}` AEAD,
  key derived from operator seed); door refuses plaintext; inference-boundary
  redactor (`[REDACTED]`); log redaction; `agent rekey`; tombstone runbook.
- **F6 — Operator-locked base_url.** `base_url` changes fold only when
  operator-attested (proxy-exfiltration P0); agent self-config may change
  model/api_key but never base_url.
- **F7 — Engine default flip.** `llm_handler.ex` fallback moonshot/k3 →
  deepseek (`https://api.deepseek.com/v1`, `deepseek-v4-flash`,
  `DEEPSEEK_API_KEY`) — the terminal no-AgentSet state lands on the
  operator's provider.

**Why now:** T16 landed the indexing substrate (PR #8, 2026-08-13). The Wisp
tire-kick (same day) proved the daemon mechanics work end-to-end but exposed
the ergonomic cliff: booting Wisp required the full 11-flag incantation, and
nothing persisted. T17 turns "agent" from a habit into a file-backed, delta-
folded, hot-swappable, self-healing entity — the prerequisite for spawning
agents at will (the rhizomatic vision: a kyber store is a loam store).

**Success criteria (exact, testable — from the spec's ACs):**
- (a) `kyber agent new wisp --soul "..."` (no provider flags) → store +
  genesis default + seed deltas; `show` carries deepseek from the genesis
  layer (AC1/AC14).
- (b) `kyber daemon --agent wisp` boots with fold-resolved model/base_url/
  key/soul/seed-policy; live turn answers on deepseek; `Soul:` renders
  (AC2). `oracle_seed: absent` = refuse-only (AC3).
- (c) `agent set wisp --model kimi-k3` + hot-swap → next inference runs
  kimi-k3 without reboot (AC10); CLI override survives a re-fold, `status`
  shows fold-vs-live (AC23).
- (d) Per-field harness: stubbed engine fails on the changed provider →
  exactly the deltas that last set the changed fields retracted,
  `ConfigRollback` emitted, 429 never rolls back (AC12).
- (e) Door rejects plaintext secrets (AC17); `{enc}` round-trip works and a
  wrong-seed boot fails legibly (AC20); redactor strips a key from the
  assembled context, keeps 64-hex IDs (AC22); `agent rekey` rotates (AC20).
- (f) `mix test` green at baseline (644 tests pre-T17, 0 failures) + new T17
  tests; no `Process.sleep`; `mix format --check-formatted` on touched
  files; rails (deps/, spec/, SPEC.md, mix.exs, config/) untouched; real
  `~/.kyber` never touched.

**Out of scope (later loops):** multi-provider routing/fallback in one agent;
in-process siblings / multi-daemon per BEAM; property-scoped self_config
allowlists (boolean v1); sandboxed tool execution / off-box proxy keys (the
threat-model follow-ons, §2 backlog); live hot-apply beyond next-inference.

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
- **T17 residual (round-11 MEDIUM-4, accepted 2026-08-14):** `agent rekey` re-encrypts
  the API key under the new seed, but the store only learns — the OLD ciphertext stays
  in the append-only log and is readable by anyone holding the rotated-away seed.
  Structurally unfixable within the append-only atom; remedy is provider-side key
  rotation (rekey now warns and names the delta carrying the old blob). Not
  agent-exploitable (rotated seed no longer folds as operator).
- **Loop 18 — Browser tool for kyber agents (scoped 2026-08-13, WSL/Windows):** a
  dedicated Chrome instance on the WINDOWS side driven over CDP (Chrome DevTools
  Protocol) from the WSL agent — `--user-data-dir=C:\kyber-browser-profile` (NEVER the
  personal profile; full cookie/session isolation), `--remote-debugging-port=9222`,
  bound to 127.0.0.1. The agent's tool executor (tool_executor.ex registry) gains
  `browser.*` tools (goto/click/type/screenshot/read-dom) speaking CDP, behind the
  same gate as existing tools. Accounts (gmail/github) are logged in ONCE in the
  dedicated profile by the operator; sessions persist in the profile dir (a
  filesystem secret like the keyring — NOT in the delta store; T17 redactor covers
  cookie leakage). Tool grant is opt-in per profile (tool_bounds), mirroring
  self_config. Deliverable: `Kyber.Agent.Browser` CDP client + tool registrations.
- **Loop 19 — Kyber dashboard (Phoenix LiveView, scoped 2026-08-14):** a dashboard
  site with two linked views over the live harness. **View 1 — delta intake waterfall:**
  a LiveView `stream/4` attached as a `DurableStore.subscribe/1` subscriber — every
  append appears live; delta → subscriber-fire → re-emitted claim re-entering the intake
  is all visible in the flow. **View 2 — span/trace view:** OTel-style waterfall per
  agent turn; trace id = the turn's initiating `received` claim content-derived id
  (reactor pin 11 — already content-addressed and store-correlatable). Spans cover
  handler dispatch, LLM call, store append, subscriber fan-out. **Span storage = ring
  buffer (user decision):** in-memory, ETS-indexed by trace id for instant click-through;
  traces are ephemeral by design (restart clears them — the store keeps only deltas, the
  atom untouched). **Click-through:** any delta in view 1 opens view 2 — full trace if
  the id is a root, else the spans whose activity referenced it (promptRef chains).
  Emitter lives in core via the pin-1 cast seam (dropped when no collector listens — no
  new substrate deps). **Location: IN-REPO** (user decision 2026-08-14) — Phoenix +
  LiveView deps in `mix.exs`/`config/` under the AGENTS.md dashboard rail exception.
  Open forks: (a) RESOLVED — in-repo; (b) exact span boundary set;
  (c) ring buffer capacity/retention. Deliverable:
  Phoenix LiveView app + core span emitter + ring buffer + ETS trace index.

## 3. Long-Term Vision: Rhizomatic Cognition

Kyber is not a tree; it is grass. The append-only delta log preserves *how* every connection was
made; memory is portable (a kyber store is a loam store); multiplicity is native (each agent,
human, and subagent a sovereign author); and the human and the agent collaborate in the same
topological space — the vault is a lens, the store is the ground.
