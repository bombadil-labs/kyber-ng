# SPEC-3: The Substrate Contract — What the Witness Provides, What Must Grow

**Status:** Founding spec
**Depends on:** rhizomatic repo, `implementations/elixir`

---

## 1. The dependency

Kyber consumes the rhizomatic Elixir witness as a git dependency:

```elixir
{:rhizomatic, github: "bombadil-labs/rhizomatic", subdir: "implementations/elixir", branch: "main"}
```

The witness is `app: :rhizomatic`, zero runtime deps, pure Elixir, conformance Level 0
(SPEC-0 §5.1: the format layer). This keeps the substrate living in its own repo — the org's
prime directive — while kyber stays buildable anywhere with network and a BEAM toolchain.

## 2. What the witness already provides (Level 0)

| Module | What it is |
|---|---|
| `Rhizomatic.Cbor` | canonical deterministic CBOR (RFC 8949 §4.2.1 profile), tagged AST, f16/f32 shortest-float ladder |
| `Rhizomatic.Blake3` | pure-Elixir BLAKE3-256 |
| `Rhizomatic.Hash` | multihash content address (`0x1e 0x20` + digest; hex at boundaries) |
| `Rhizomatic.Base64Url` | canonical unpadded base64url |
| `Rhizomatic.Delta` | claims boundary validation + canonical bytes + id (SPEC-1 §2/§4.1) |
| `Rhizomatic.Profile` | JSON debug profile parser — the ONE blessed int→float point |
| `Rhizomatic.Ed25519` | strict five-check verification (SPEC-1 §5.1), hand-rolled |
| `Rhizomatic.Signer` | author↔key match on sign; verify = id recomputes, then strict Ed25519 |
| `Rhizomatic.SetDigest` | provisional membership digest |
| `Rhizomatic.Pack` | SPEC-8 L0 pack: build (byte-deterministic) + unpack |

Conformance discipline: the witness loads `vectors/` directly and asserts byte-exact canonical
output. Kyber inherits that correctness — it does not re-derive it.

## 3. What must grow (and where it lives)

The evaluator and reactor do **not** exist in Elixir yet. Per D8, that is substrate work in the
rhizomatic repo — the witness's own CLAUDE.md says "L1+ only when a consumer needs it", and kyber
is the consumer. The roadmap, owned by the substrate repo:

- **L1 — the evaluator**: the ten operators as a pure function over in-memory delta sets; the
  `rhizomatic.HyperSchemaSchema` bootstrap pinned. Byte-for-byte against the vectors, parity with
  TS/Rust.
- **L4 — the reactor**: ingest, the four core indexes, materializations (`register`/`materializedView`/
  `subscribe`), incremental maintenance with the incremental-equivalence property.
- **L5 — resolution**: policies (`pick`/`all`/`merge`/`conflicts`/`absentAs`), orders, views.

Until L1/L4 land in Elixir, kyber's Loops 1–2 build only on Level 0: claim construction, signing,
verification, set-union merge. The reactor loop in kyber's backlog (PLAN §2) is gated on the
substrate's L4 landing — or, if Myk prefers, kyber drives the substrate PRs itself as part of its
loops (the "build the suite alongside the thing" rule cuts both ways).

## 4. The contract, restated

1. Kyber never edits the witness. A genuine substrate need = a PR to rhizomatic + a conversation
   with Myk (loam's hard limit, adopted verbatim).
2. Vectors first. Any behavior kyber needs from the substrate gets a vector in the substrate repo
   before or alongside its code.
3. When implementation contradicts spec, the contradiction is the deliverable: record it in
   `ERRATA.md`, propose the amendment, never silently diverge (rhizomatic README).

**Provenance.** Founding — Hermes, 2026-08-06, from `implementations/elixir/CLAUDE.md` and loam
SPEC §2 (the foundation section this repo mirrors).
