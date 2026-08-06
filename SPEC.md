# Kyber — Specification

**Kyber is an agent harness standing on rhizomatic ground.** A sovereign LLM agent — Discord,
cron, tools, memory — whose every event is a signed, content-addressed, loam-compatible claim.
The harness is the tree; the ground is the delta set; loam is the ground's reference deployment.

The first kyber was written before rhizomatic existed. Its architecture — append-only delta log,
pure reducer, effect system, event-driven input saturation — was the rhizome *before the format*:
the same shape, without the atom. This repository is the unification: the harness keeps its
Elixir/OTP soul, and its deltas become rhizomatic claims, byte-for-byte compatible with
[loam](https://github.com/bombadil-labs/loam). Two kyber instances that meet merge; a loam gateway
can serve a kyber store; a kyber agent can federate with any loam peer.

The design is in [`spec/`](spec/), one file per layer, numbered. Cross-references use the bare form
**§N** — §N is the file whose name begins with that number.

| § | Section |
|---|---------|
| §0 | [The unification — architecture & the DNA mapping](spec/00-overview.md) |
| §1 | [The event vocabulary — kyber events as claims](spec/01-events.md) |
| §2 | [Identity — authors, keys, capabilities](spec/02-identity.md) |
| §3 | [The substrate contract — what the witness provides, what must grow](spec/03-substrate.md) |
| §4 | [Persistence — the store only learns](spec/04-persistence.md) |
| §5 | [The harness — OTP plugins as subscriptions, effects as write-back](spec/05-harness.md) |
| §6 | [Federation — kyber as a loam peer](spec/06-federation.md) |
| §7 | [Migration — old kyber deltas, new kyber claims](spec/07-migration.md) |

## Hard limits

- **rhizomatic is frozen/normative.** Never edit it from here. The substrate is consumed as a
  dependency (git dep on `implementations/elixir`, §3). A genuine substrate need is a PR to
  `bombadil-labs/rhizomatic` + a conversation with Myk — the same rule loam lives by.
- **The atom is not renegotiable.** Identity is content-derived (P6). Merge is union. Retraction
  is negation. If a design pressure suggests otherwise, the design is wrong, not the format.
- **Byte-compatibility with loam is a conformance claim.** A kyber delta must parse through the
  witness's JSON debug profile and hash identically on any conformant implementation. The vectors
  are the contract; the contradiction is the deliverable (rhizomatic README, "Rules of engagement").

**Provenance.** Founding spec — written by Hermes (Veles) at repo initialization, 2026-08-06, from
the unification analysis of `bombadil-labs/{rhizomatic,loam,kyber}`. Sections land their own
provenance as they gain implementation.
