# SPEC-4: Persistence — The Store Only Learns

**Status:** Founding spec; Loop 1 implements the minimal in-memory set
**Depends on:** SPEC-0 (D5), rhizomatic SPEC-1 §8 (delta set algebra)

---

## 1. The store is a grow-only set

The unit of storage is the **delta set**: a mathematical set of deltas, deduplicated by id
(rhizomatic SPEC-1 §8). Merge is union — commutative, associative, idempotent. Two kyber instances
that meet merge; a lagging copy is merely behind, never wrong.

## 2. Physical layers (in build order)

- **Loop 1: in-memory `DeltaSet`** — a map of id → delta, with `merge/2`, `member?/2`, `size/1`.
  Pure. This is the substrate's own delta-set operation (SPEC-1 §8) — the witness may already
  expose it; if not, kyber's wrapper is 20 lines of map algebra.
- **Loop 2: append-only JSONL of wire deltas** — the JSON debug profile (rhizomatic SPEC-1 §4.2),
  exactly the shape loam's `POST /:mount/append` accepts. Replay = re-verify + re-merge. This is
  the direct successor of old kyber's `deltas.jsonl` — but the records are now claims, verified on
  the way in.
- **Later: sqlite or packs** — loam's `SqliteBackend` seam or the SPEC-8 pack format. The `StoreBackend`
  seam pattern (async append / `deltasSince` / close) from loam §"Deploy" is the target shape, so a
  driver can drop in without touching the event layer.

## 3. The door

Every delta enters through one door: **verify, then merge**.

1. Parse (JSON debug profile → canonical form).
2. Recompute the id from claims; reject if it does not match (content addressing).
3. Verify the signature (strict, witness `Signer`). Unsigned claims are refused (D1).
4. Merge into the set. Duplicates are no-ops (union).

The door is the same shape as loam's append door — which is the compatibility claim: a delta kyber
emits is a delta loam accepts, byte for byte.

## 4. Ephemeral events are not deltas (D5)

`cron.fired` heartbeats and transient internal signals never reach the delta layer. They are OTP
messages that may *trigger* a fact (a `message.sent`, a `tool.exec`) but are not themselves facts.
Rationale: the old kyber's broadcast-only hack (`@ephemeral_kinds ~w(cron.fired)`, 400K deltas in
42 hours) was a symptom of the wrong boundary — the store was being asked to remember pulses. The
store only learns facts; pulses pass through the harness.

## 5. Nothing is deleted

- Retraction is negation (§1-events 2.6): a new claim masking an old one. Both remain in the set.
- Erasure (GDPR-style) is loam's operator-only act, available only if the store is governed (§2
  identity) — the tombstone pattern, never content deletion. Not in scope until federation lands.
- "Current state" is a lens, not a field. Time-travel is a filter on claimed timestamps
  (rhizomatic SPEC-1 §6).

## 6. The session cap is a lens

Old kyber capped session history at 20 messages. In the new shape the cap is a **materialization
bound** (a view that gathers the most recent N), never a store property. The store remembers
everything; the lens decides what the agent sees. (Lens mechanics arrive with L4/L5 substrate
work; until then, harness-side gathering is explicitly provisional.)

**Provenance.** Founding — Hermes, 2026-08-06. §4 resolves the old kyber ephemeral-delta tension;
§6 resolves the session cap.
