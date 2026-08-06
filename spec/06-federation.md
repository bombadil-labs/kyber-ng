# SPEC-6: Federation — Kyber as a Loam Peer

**Status:** Founding spec; implementation gated on persistence + substrate reactor
**Depends on:** SPEC-2 (identity), SPEC-4 (persistence)

---

## 1. The claim

A kyber store IS a loam-compatible store at the delta level. This is not an integration; it is the
consequence of the atom. Any loam gateway can ingest kyber's deltas (`POST /:mount/append`, §4
persistence: same shape, same verification); kyber can pull from a loam peer; trust is a lens the
reader holds, never a write denial (loam §"Federation").

## 2. The payoffs

- **Portable memory.** Export kyber's delta set; import it into a loam instance; serve the agent's
  memory over GraphQL. The same store, proven hash for hash — the tutorial's promise, applied to
  an agent's mind.
- **Multi-agent multiplicity.** Two kyber instances (or a kyber and a loam) that meet merge. Each
  instance has its own operator seed; a peer's self-signed grant merges as a delta and governs
  nothing (loam's constitutional honesty).
- **Chorus convergence.** Chorus (agent memory) was reborn as a loam app; kyber is the harness that
  such schemas run inside. The shared vocabulary (§1-events D4: `loam:store`, `loam.registration`,
  `loam.trust`) is what makes the same ground governable and serveable by both.

## 3. The door, outward

- Signatures required at the boundary (rhizomatic SPEC-1 §5: any delta crossing a federation
  boundary needs signature coverage).
- Admission posture is loam's: `open` (admit everything that verifies — the aggregator's stance),
  `roster`, or `closed`, declared as claims at `loam:trust` and resolved live on every pull.
- An explicit `admit` predicate overrides. Foreign law stays inert.

## 4. What kyber must build (later loops)

- A `pull` operation (loam's `pullFrom` shape): fetch a peer's published deltas, verify, union.
- An offer/federate surface (loam's `GET /:mount/federate` shape), with an `offeredLens` if kyber
  wants to publish selectively.
- Governance wiring (§2 identity §4): human-as-operator, agent-as-grantee, when the store is
  governed.

**Provenance.** Founding — Hermes, 2026-08-06, from loam's federation model. Gated: needs §4
persistence (a durable set to pull into) and the substrate's reactor for live views.
