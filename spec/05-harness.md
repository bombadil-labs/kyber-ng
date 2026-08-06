# SPEC-5: The Harness — OTP Plugins as Subscriptions, Effects as Write-Back

**Status:** Founding spec (architecture); harness build-out is later loops
**Depends on:** SPEC-0 (D7), SPEC-1 (vocabulary), SPEC-4 (the door)

---

## 1. What stays

The harness is the Elixir/OTP soul of kyber and it stays: plugins (Discord, LLM, cron, voice),
tools, supervision, the LiveView dashboard. GenServers, DynamicSupervisors, `rest_for_one` — all
the machinery that made old kyber reliable. What changes is the *boundary*: plugins no longer emit
`Kyber.Delta` structs with kinds; they emit signed claims through the door (§4), and they *fire*
from subscriptions rather than imperative chains.

## 2. The pipeline (old → new)

```
OLD:  emit(delta) → Store.append → Reducer.reduce → {state, effects} → Executor.execute
NEW:  emit(claim) → Door (verify, merge) → Reactor (indexes, materializations) → subscriptions → plugins act → write-back claim
```

Input Saturation, which old kyber hand-rolled (`message.received → prompt.annotated → llm_call`),
becomes the substrate's native shape: a plugin subscribes to a materialization (e.g. "incoming
messages at `channel:discord:…`"), and the function fires when the inputs condense — not because
someone called it.

## 3. The write-back loop (D7)

A side effect is two claims separated by a real-world act:

1. The **intention** — e.g. `llm.response` lands (SPEC-1 §2.3).
2. The plugin (a subscription handler) performs the act — sends the Discord message.
3. The **record** — `message.sent` lands, `caused_by` the response (SPEC-1 §2.4).

Nothing real happens unrecorded; nothing recorded is unverifiable. The old `Effect.Executor`
handler registry survives as the *subscription dispatcher*: an effect type is a subscription on a
materialization shape; a handler is the thing that acts and writes back.

## 4. Plugin map

| Old plugin | New shape |
|---|---|
| LLM | A subscription on `prompt.annotated`; signs responses as the agent (§2 identity); the tool loop emits `tool.exec` claims |
| Discord | Ingest signs `message.received` as the human; outbound acts on `message.sent` intent; reactions/typing are ephemeral OTP signals, not claims |
| Cron | Schedules may become `cron:<id>` claims (later loop); firings are OTP pulses (D5) — a firing may *trigger* a fact, never be one |
| Voice | Unchanged boundary: world-facing; its events enter as claims |
| Memory/Consolidator | Reads the delta set as its ground truth; writes consolidated facts as claims; the vault is a materialized view (D6) |

## 5. Testing conventions (carried from old kyber, binding)

- Pure reducers: test state + effects/claims, not just state.
- No `Process.sleep` in tests — `assert_receive/3`, `catch_exit`, or explicit state polling.
- ExUnit integration tests exercise the door end-to-end: emit → verify → merge → subscription fires.

**Provenance.** Founding — Hermes, 2026-08-06, from old kyber's `core.ex`/`reducer.ex` and the
rhizomatic reactor's subscription model (SPEC-4 of the substrate).
