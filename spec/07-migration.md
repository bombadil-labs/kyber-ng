# SPEC-7: Migration — Old Kyber Deltas, New Kyber Claims

**Status:** Founding spec; implementation gated on the event layer (Loop 1)
**Depends on:** SPEC-1 (vocabulary), SPEC-2 (identity)

---

## 1. The old record

Old kyber persisted `deltas.jsonl` — one JSON object per line:

```json
{ "id": "4a7f…", "ts": 1754512345678, "origin": {"type": "channel", "channel": "discord", "chat_id": "…", "sender_id": "…"}, "kind": "message.received", "payload": {"text": "hello"}, "parent_id": null }
```

## 2. The import

Each old delta becomes one or more signed claims per SPEC-1's templates. The mapping:

| Old field | New home |
|---|---|
| `id` (random) | Not preservable — identity is content-derived (P6). Recorded as lineage, see below. |
| `ts` | `claims.timestamp` (as a float; the JSON debug profile's one blessed int→float point) |
| `origin.type = channel` | `by` pointer → `human:<sender_id>` if a human is identifiable; else `agent:<name>`; the channel/chat ids → `channel:`/`message:` entities |
| `origin.type = cron` | Schedule → `cron:<id>` claim (future loop); firings are dropped (D5 — pulses were never facts) |
| `origin.type = subagent` | `subagent:<id>` entity; the parent linkage → a DeltaRef where the parent survives |
| `origin.type = tool` | `tool.exec` template (§1-events 2.5) |
| `origin.type = human` | `by` → the human's key (imported per §2 identity) |
| `origin.type = system` | Agent-authored, `kyber.system` role |
| `kind` | The claim template (the whole §2 table of SPEC-1) |
| `payload` | Pointers per template; unknown keys → a `kyber.legacy` payload claim (Bytes) so nothing is lost |
| `parent_id` | `annotates`/`during`/`caused_by` DeltaRef where the parent survives; else `rhizomatic.txn.prior`-style linkage |

## 3. Lineage

A migration pass emits, alongside each imported claim, a lineage annotation signed by the agent:

```json
{ "claims": { "timestamp": …, "author": "ed25519:<agent>",
    "pointers": [
      { "role": "kyber.migrated", "target": { "delta": "<imported claim id>" } },
      { "role": "kyber.legacy_id", "target": "4a7f…" }
    ] } }
```

The old id is preserved as a *claim about* the new claim — audit survives the rewrite.

## 4. The vault

The Obsidian vault's markdown imports as `Bytes` claims (mime `text/markdown`) with `kyber.vault`
roles, filed at the concept entities. Post-migration, the vault is a materialized view (D6): the
files on disk are the lens, the claims are the ground. (Vault import is its own loop; §1-events
open questions apply.)

**Provenance.** Founding — Hermes, 2026-08-06, from old kyber's `delta.ex` serialization and
PLAN.md. The lineage pattern mirrors loam SPEC §20 (migration) in miniature.
