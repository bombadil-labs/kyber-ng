# SPEC-1: The Event Vocabulary — Kyber Events as Claims

**Status:** Founding spec; Loop 1 implements the core templates
**Depends on:** SPEC-0 (§3 mapping), rhizomatic SPEC-1 (the atom)

---

## 1. Entities

Entity ids are opaque strings; kyber mints them with a namespace prefix. A pointer is a string that
matches or doesn't (loam: entities are unowned).

| Prefix | Meaning | Example |
|---|---|---|
| `agent:` | the agent itself | `agent:kyber` |
| `human:` | a human participant | `human:myk` |
| `channel:` | a messaging channel | `channel:discord:123456789012345678` |
| `message:` | a message (incoming or outgoing) | `message:discord:123456789012345678:987654321098765432` |
| `session:` | a conversation session | `session:discord:123456789012345678` |
| `tool:` | a tool invocation | `tool:exec`, `tool:web_fetch` |
| `subagent:` | a sub-agent instance | `subagent:research-01` |
| `cron:` | a scheduled task definition | `cron:daily-digest` |

## 2. Claim templates (core events)

A claim template names the pointers an event emits. Each event is **one delta** (SPEC-1 §3:
atomicity — if a fact can be independently wrong, it is a separate delta; these are not).
`claims.timestamp` carries the author's claimed time; no event duplicates it as a pointer.

### 2.1 `message.received` — a human (or remote) message arrives

Author: the **human's key** (§2) — sovereignty: the claim is theirs.

```json
{
  "claims": {
    "timestamp": 1754512345678.0,
    "author": "ed25519:<human key hex>",
    "pointers": [
      { "role": "received", "target": { "id": "message:discord:…:…", "context": "incoming" } },
      { "role": "at",       "target": { "id": "channel:discord:…", "context": "messages" } },
      { "role": "by",       "target": { "id": "human:myk", "context": "sent" } },
      { "role": "content",  "target": "hello Veles" },
      { "role": "session",  "target": { "id": "session:discord:…", "context": "messages" } }
    ]
  }
}
```

`content` is a string primitive for text. For rich payloads (embeds, attachments, images) use a
`Bytes` target (`{ "role": "attachment", "target": { "mime": "image/png", "value": "…" } }`).

### 2.2 `prompt.annotated` — the annotator has saturated the prompt (Input Saturation)

Author: the **agent's key** (the annotator is the agent acting as a derived author).

```json
{
  "claims": {
    "timestamp": 1754512347000.0,
    "author": "ed25519:<agent key hex>",
    "pointers": [
      { "role": "annotates", "target": { "delta": "<message.received id>", "context": "annotated" } },
      { "role": "notes",     "target": "salience: L0 tags [kyber, rhizome]; L1 summary …" }
    ]
  }
}
```

The `annotates` pointer is a **DeltaRef** — Merkle causation, the successor to `parent_id`.

### 2.3 `llm.response` — the model has answered the annotated prompt

Author: the **agent's key**.

```json
{
  "claims": {
    "timestamp": 1754512350000.0,
    "author": "ed25519:<agent key hex>",
    "pointers": [
      { "role": "responds", "target": { "delta": "<prompt.annotated id>", "context": "answer" } },
      { "role": "content",  "target": "…the model's reply…" },
      { "role": "usage",    "target": { "id": "agent:kyber", "context": "tokens" } }
    ]
  }
}
```

Token accounting rides as a separate claim or an annotation delta (later loops); the response claim
itself stays minimal.

### 2.4 `message.sent` — the agent's reply was delivered to the world (write-back)

Author: the **agent's key**.

```json
{
  "claims": {
    "timestamp": 1754512351000.0,
    "author": "ed25519:<agent key hex>",
    "pointers": [
      { "role": "sent",     "target": { "id": "message:discord:…:out-<id>", "context": "outgoing" } },
      { "role": "via",      "target": { "id": "channel:discord:…", "context": "sent" } },
      { "role": "content",  "target": "…the delivered text…" },
      { "role": "caused_by", "target": { "delta": "<llm.response id>" } }
    ]
  }
}
```

`caused_by` makes the delivery causally pinned to the response that produced it (D7: the act is
recorded, and its cause is verifiable).

### 2.5 `tool.exec` — a tool ran and produced a result

Author: the **agent's key** (the agent is the tool's principal; a subagent's tools are the
subagent's).

```json
{
  "claims": {
    "timestamp": 1754512348000.0,
    "author": "ed25519:<agent key hex>",
    "pointers": [
      { "role": "tool",   "target": { "id": "tool:exec", "context": "invocations" } },
      { "role": "args",   "target": "ls -la /tmp" },
      { "role": "result", "target": "total 8\ndrwxrwxr-x …" },
      { "role": "during", "target": { "delta": "<prompt.annotated id>", "context": "tool_use" } }
    ]
  }
}
```

Sensitive results (secrets, keys) must never ride as primitives — use `Bytes` with a restrictive
lens, or keep the result off-claim and reference it (later loops; the posture is loam §14's
"immutable by default" for reads).

### 2.6 Retraction (the only "delete")

Clearing a value, withdrawing a statement, or striking a message is **negation**, authored by the
same key that authored the target (loam §14: retract-your-own is the whole reach):

```json
{
  "claims": {
    "timestamp": 1754512400000.0,
    "author": "ed25519:<the original author's key>",
    "pointers": [
      { "role": "negates", "target": { "delta": "<the target delta id>", "context": "audit" } },
      { "role": "reason",  "target": "sent in error" }
    ]
  }
}
```

## 3. What is NOT an event

- **`cron.fired`** — a pulse, not a fact (D5). The schedule *definition* may become a claim later
  (`cron:<id>` entity, `schedule` role); the firing never does.
- **Transient internal signals** (plugin load order, heartbeat routing) — OTP messages, not deltas.
  The store only learns facts.

## 4. Vocabulary namespace

- Roles/contexts above are bare words — meaning is vocabulary, not atom law.
- Kyber-specific normative semantics (e.g. what "annotates" commits to) live under the reserved
  `kyber.*` vocabulary when they need machine-checkable meaning (mirroring `rhizomatic.txn.*`,
  `loam.registration`).
- Store-participation vocabulary is loam's: `loam:store`, `loam.registration`, `loam.trust` — a
  loam gateway must be able to govern and serve this ground without translation (D4).

## 5. Open questions

- **Tool result policy.** Whether tool results ride in-claim (2.5) or are referenced needs a
  security pass (secrets in the delta set are secrets in every federation copy). Tracked for the
  tools loop.
- **Session cap.** Old kyber capped session history at 20 messages. In the new shape the cap is a
  **lens** (a materialization bound), never a store property — the store remembers everything
  (§4). The exact bound policy is a harness concern.

**Provenance.** Founding — Hermes, 2026-08-06, from the old kyber reducer's kind table
(`reducer.ex`) mapped through SPEC-0 §3. Loop 1 implements §2.1–§2.5.
