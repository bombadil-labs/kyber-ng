# T11b — The Inference Chain (claude fork)

Rev 1 — fork of the shared T11b contract for the claude leg of the three-way blind taste test (T11b rematch 2026-08-06). Same contract as its siblings; amendments to THIS file only.

## Post-verdict amendments (blind taste test, 2026-08-06 — merged winner)

The three-way verdict (Fable 5 judge, anonymized A/B/C): **A (this leg) won 23–21–17** — the only
build with NO window where a guarantee silently breaks. Its strictly-below-the-prompt
`conversationRef` anchor (the judge's single best idea) makes the re-fired request a function of
the store *beneath* the prompt, so crash-window leftovers can never shift the content address;
its crash test drops checkpoints from the real log, re-boots with a differently-answering stub,
and asserts the ORIGINAL answer survives with `refute_receive {:llm_request, _}`. Loser findings
(judge): B's boot catch-up re-fires every session prompt (summaries shift `conversation_ref` →
non-byte-identical re-fires → duplicate answers on long sessions) — NOT folded; C's re-fire
includes its own persisted request (dedup misses) — NOT folded. Per the judge's per-loser
attributes, two folds landed in the merged tree:

1. **B's native tool protocol** (folded): `LlmHandler.chat/3` accepts OpenAI `tools` + parses
   `message.tool_calls` (malformed entries refused, never partial); the engine emits one
   `ToolCall` delta per model call with the SEMANTIC args unwrapped from the native arguments
   JSON, and reconstructs the assistant `tool_calls` message on resume with provider ids
   synthesized DETERMINISTICALLY from the ToolCall delta's content address (restart-stable —
   the same id the API accepted). The `TOOL:<id>` text protocol is gone.
2. **B's spine-8 checkpoint** (folded): the engine emits ONE deterministic
   `ConversationSummary` (response-timestamped, SHA-256 digest of the elided head, covers the
   elided turn ids) once a session's conversation exceeds twice the window — the lens artifact
   the window lens prefers beyond its bound. The LLM-backed summarizer reactor stays T11c's.
3. **C's delivery leg** — NOT folded: A's `message.sent` delivery already claims the response's
   timestamp (content-address dedup), the same determinism C's leg was praised for.
4. **B's `PointerWalk` lens** — recorded as a future refactor (elegance-only; the merged engine
   carries the walk inline).

## Post-live-run findings (AC4/AC5 operational run, 2026-08-06 — recorded)

- **kimi-k3 accepts ONLY `temperature: 1`** — the handler's 0.6 drew a 400 (`invalid
  temperature`). Fixed to 1.0. A live-API constraint NO stub test can catch — the AC4 run is
  the only place it surfaces.
- **`:inets`/`:ssl` bootstrap** — the app declares only `:logger` extra, so mix prunes the OTP
  code path; live runs must add the OTP ebins back (recorded in the run script).
- **`tool_choice: "auto"` can be declined**: kimi-k3 answered in text rather than calling the
  tool in the probe (the native protocol path remains stub-proven; forcing `tool_choice` is a
  policy decision for the deployed harness).
- The operational run itself: real question in → real kimi-k3 answer (`"Paris"`) persisted as
  `message.sent`; the AC5 grounded follow-up (`"Which city was my previous question about?"`)
  answered `"Paris"` — the model read its own prior claim from the store; SIGTERM; re-boot;
  resume `%{resumed: 0, waiting: 0}`; sent count unchanged — no duplicate, answer persisted.


Original Rev 1 — slice spec of the T11 umbrella contract (`.adlc/specs/T11.md`; spine pins 1, 2, 3, 4, 5, 6, 8, 9, 10 —
deltas-as-events, entities-as-resolutions, intake-takes-deltas, primitives-ride/composites-point, the pointer is
the crash-window guarantee, actors bound to containers, windows-as-lenses, tool-chains-as-linked-deltas,
rendering-as-lens). T11a (the schema layer) is landed and merged; this slice sits on top of it.

## Why this loop exists

T10 built the operational harness with a deterministic ack stub. T11a pinned the vocabulary. THIS slice swaps
the stub for a real model: an actual LLM (Moonshot Kimi K3) becomes a gather handler, so an event in →
signed claim → model action → response claim loop runs with non-deterministic, real content. The gate is an
operational run: a real question in, a real answer out, persisted, crash-safe, grounded.

## Carried contract additions (from the T11a close-out — binding here)

1. **The door/schema seam (three-way wash, all three T11a builds flagged it):** `Kyber.Schema.validate/1`
   is threaded into the daemon's admission — every delta that DECLARES a known lifecycle type is validated at
   the door (ill-shaped → refused, reject never repair; unknown → raw admission). The infra emitters
   (`Kyber.Events`) gain type declarations so their output validates typed.
2. **Boot-time rehydration (T11a premortem HIGH):** the schema container rehydrates observed evolution at
   boot — it replays the store's schema deltas (superseding/negating entries) on top of the genesis set
   before serving, so a reboot never reverts the vocabulary under the store (spine 6 carried into the slice).
3. **Resolve contract (T11a premortem):** typed access answers a plain map (`%{type, author, timestamp,
   fields…}`); the codegen struct is optional sugar, used only while it still fits the LIVE schema (fields ⊆
   struct keys AND struct fields ⊆ schema fields).

## Deliverables

- **`Kyber.Agent.LlmHandler`** — OpenAI-compatible client (Moonshot base `https://api.moonshot.ai/v1`,
  key `MOONSHOT_API_KEY`, model `kimi-k3`; stdlib `:httpc`/`:ssl` — zero new deps) implementing the
  gather contract `(delta[]) -> delta[]` with REAL non-deterministic content. The HTTP client is injectable
  (a stub adapter for tests; the real adapter for the live run) — the seam is a behaviour, not a module swap.
- **`Kyber.Agent.ContextBuilder`** — session-container actor: maintains the conversation hyperview
  (gather-into via `Kyber.Schema.resolve_entity/2`), applies the window lens (last N turns + summaries),
  injects memories through the **`Kyber.Agent.MemoryPort`** retriever seam (an interface: `retrieve/2` —
  a memory container behind it is T11c's job; a stub retriever serves this slice), emits one thin
  `InferenceRequested` delta per prompt (primitives ride, composites point — no conversation text).
- **`Kyber.Agent.Engine`** — stateful inference handler: fires on `InferenceRequested`, rehydrates
  context by pointer-walk, calls the model via the handler, emits `ResponseDelta` (or `ToolCall` deltas
  mid-turn), holds in-flight turn state in its process, resumes from the chain on restart.
- **Tool executor handler(s)** — fire on `ToolCall`, emit `ToolResult`.
- **`Kyber.Agent.MemoryPort`** — the retriever seam (behaviour + stub).
- **CLI: `kyber agent`** — boots daemon + container actors on a configured (tmp) store/keyring;
  bounded, T8/T9 discipline.

## Acceptance criteria (from the umbrella, owned by this slice)

- **AC1 — The LLM handler is real and dependency-light:** `Kyber.Agent.LlmHandler` calls Moonshot
  (`MOONSHOT_API_KEY`, `kimi-k3`) with REAL non-deterministic content and zero new deps (stdlib
  `:httpc`/`:ssl` only; `mix deps` diff vs T10 is empty). verify: a test runs the handler against a
  canned Moonshot response (the stub HTTP adapter) AND a live smoke calls the real API once;
  `git diff 36205ba..HEAD -- mix.exs` is empty.
- **AC3 — Re-boot idempotence holds WITH the LLM handler (the pointer guarantee):** daemon kill
  between the ack and the checkpoint with an in-flight LLM exchange → re-boot → the exchange does NOT
  duplicate (byte-identical re-fire → content-address dedup) and the answer claim persists exactly
  once. verify: the crash-window test (manufacture ack-persisted / checkpoint-lost, then re-boot)
  asserts one request delta, one response delta, and a counted skip.
- **AC4 — The operational run (THE gate):** Hermes boots the daemon on a tmp store/keyring with the
  LLM handler live; CLI-ingests a `message.received` whose content is a real question; the context
  builder fires, the model answers, the answer persists as `message.sent` (agent-signed,
  non-deterministic); the vault renders the exchange; SIGTERM; re-boot; no duplicate; the answer is
  still in the store. Bounded explicit polling, never `Process.sleep`. verify: the recorded operational
  run (this exact sequence) is the loop's acceptance evidence, machine-checked by the smoke.
- **AC5 — The store is the memory (grounded follow-up):** the handler's SECOND invocation is grounded
  in the FIRST exchange — the model sees its own prior `message.sent` claims and answers a follow-up
  that REQUIRES that memory ("what did I just say?"). verify: the second answer's content references
  the first exchange's content (asserted in the test).
- **AC8 — Tool chains are linked deltas:** a turn with a tool call produces `ToolCall` → executor →
  `ToolResult` → final `ResponseDelta`, each persisted and pointer-linked; the engine's in-flight
  state survives a daemon restart (the chain is the state); the UI projection is a lens — the smoke
  asserts the chain renders as prompt + final response with tool steps available (the projection API,
  not a special store path). verify: the tool-chain test with a stub executor asserts the link
  sequence, a mid-chain restart resumes, and the projection shows both collapsed and expanded views
  of the same store.
- **AC9 — The deterministic loop is the fallback, not a casualty:** with the LLM path disabled, the
  T10 built-in ack loop still works. verify: the T10 daemon/agent_loop tests stay green unchanged.
- **AC10 — Gates:** no `Process.sleep` in test/ (send_after/assert_receive only); rails (deps/,
  spec/, SPEC.md, mix.exs, config/) frozen — rails-guard clean; the real `~/.kyber` never touched
  (tmp store/keyring everywhere); format clean; warnings-as-errors clean; the memory container is
  swappable behind the MemoryPort seam (the A/B property). verify: `grep -r "Process.sleep" test/`
  empty; rails-guard passes; `mix format --check-formatted` clean; `mix compile --force
  --warnings-as-errors` clean.
