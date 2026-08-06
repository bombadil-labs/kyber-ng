# SPEC-2: Identity — Authors, Keys, Capabilities

**Status:** Founding spec; Loop 1 implements the keyring core
**Depends on:** SPEC-0 (D3), rhizomatic SPEC-1 §5

---

## 1. Authors

An author is an Ed25519 keypair. The author id on a claim is `"ed25519:" + lowercase hex of the
32-byte public key` (rhizomatic SPEC-1 §5). There is exactly one author per delta; a delta's
`origin` (old kyber) is expressed by *who signed* plus *what the pointers name* (SPEC-0 §3).

## 2. The keyring

`Kyber.Keys` is the only module that touches key material (and the only file I/O in the event
layer). Its duties:

- **Agent seed** — minted on first init (0600 file, never printed — loam's operator discipline),
  importable via `KYBER_SEED` (hex), stored under the home dir (default `~/.kyber/keys/`).
- **Human keys** — imported (the human's own key) or minted on first contact. A human's messages
  are signed as *them*: `message.received` by `human:myk` carries the human's signature (SPEC-1
  §2.1). This is the sovereignty move — the human's claims are theirs, the agent's are the
  agent's, and no central identity mints either.
- **Subagent keys** — minted per subagent instance, scoped, revocable by the parent's negation of
  the grant that admitted them (§4). A subagent is a derived author (SPEC-7): own key, own budget,
  outputs re-enter as signed claims. This is old kyber's `{:subagent, parent_delta_id}` origin,
  given identity.

## 3. Signing discipline

- Every delta the harness emits is signed by the **emitting author's** key. The LLM plugin signs as
  the agent; the Discord message intake signs as the human; a subagent signs as itself.
- Signature acceptance is the witness's strict criterion (rhizomatic SPEC-1 §5.1) — never a
  library default. The witness's `Rhizomatic.Signer` is the one verifier.
- Unsigned deltas are refused at the door (D1). The old kyber accepted unsigned internal deltas;
  the new kyber has no internal dialect to exempt.

## 4. Capabilities (loam's model, when governed)

A kyber store may be:

- **Ungovemed** (default for a solo local store): any verified delta is welcome.
- **Governed**: a store entity `loam:store` roots the chain. The **human is the operator** (roots
  the chain, needs no grant); the **agent holds a `write` grant**; subagents hold grants minted by
  the agent (admin can mint, per loam §"Capabilities"); a peer's self-signed grant governs nothing.

When a kyber store federates with a loam instance (§6), governance follows that instance's
operator — kyber asks for standing like any author, and a grant-shaped delta from a non-admin
*lands and binds nothing* (loam's constitutional honesty).

## 5. Key material handling

- Seeds are hex, written 0600, never logged, never printed (`loam init` discipline).
- `KYBER_SEED` env import for containers (mirrors `LOAM_SEED`).
- The keyring's author derivation is pure: `author_for_seed(seed) → "ed25519:…"` (the witness
  already provides `authorForSeed` semantics; the Elixir witness's `Signer` covers sign/verify).

**Provenance.** Founding — Hermes, 2026-08-06, from loam's capability model + old kyber's origin
tuples. Loop 1 implements: agent seed mint/load, human key import, author derivation, sign-by-role.
