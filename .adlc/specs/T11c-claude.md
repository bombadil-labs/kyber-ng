# T11c — The Memory Store (claude fork)

Rev 1 — fork of the shared T11c contract for the claude leg of the three-way blind taste test (T11c rematch 2026-08-06). Same contract as its siblings; amendments to THIS file only.

## Post-verdict amendments (blind taste test, 2026-08-06 — merged winner)

The three-way verdict (Fable 5 judge, anonymized A/B/C): **A (this leg) won 24–19–18** — the
only build with no silent guarantee-break: provenance derived from the head's attestation (a
non-human edit stays `:auto`, pinned by test), the watcher a stateless tick returning wires for
the caller to admit, collision-proof filenames, every failure window pinned (garbled file,
drift-free tick, refused wire, old-content-by-pointer). Judge's per-loser attributes, folded:

1. **C's single best idea — provenance is AUTHORITY, not label:** the watcher signs
   `MemoryEdited` with the HUMAN's key; resolution derives `:human` from the head edit's SIGNER
   (a known `human_author`), not from the `reason` string. The spoof-pin test: an agent-signed
   edit labelled `"human_edit"` is `:auto` under a known human key — the overclaim B shipped
   and could not test. Until boot wiring carries the operator key (`human_author == nil`), the
   reason-string rule remains the documented fallback. API: `Memory.canon/3` +
   `resolve_set/2`; the retriever threads `human_author` in its state.
2. **B's best attribute — three-way A/B equality:** a second container rehydrated by replay
   from the same store serves identical queries; container A == container B == the bare pure
   path, asserted end-to-end, plus the determinism clause (byte-identical re-fire of the same
   store read).
3. **NOT folded:** B's sticky provenance (ANY edit in the chain → `:human` — silent overclaim)
   and its failing format gate; C's stateful machinery (incremental cache + 100-hop bound where
   a pure fold suffices), slug-only filenames (collisions silently overwrite), and its
   trim-all-trailing-newlines normalization.

**Deliverable finding (recorded, both B and C converged independently):** AC6's
`source: :human_edit` + old+new-content slots have NO room in the closed genesis schema —
a literal `source` role is refused at admission. The mapping: NEW content inline; OLD content
rides the `edits` pointer (composites point — the superseded canon head's delta carries it);
the marker rides the optional `reason` string; authority rides the SIGNATURE. The AC6 test
asserts the delta validates strictly-typed, so the mapping is pinned, not assumed.

Original Rev 1 — slice spec of the T11 umbrella contract (`.adlc/specs/T11.md`; spine pins 2, 5, 6, 7, 9, 10 —
entities-as-resolutions, primitives-ride/composites-point, containers-are-caches-rehydrate-by-replay,
memory-is-entities-not-deltas, the MemoryPort A/B seam). Slice of the T11 split: this ticket owns
**AC6 + AC10** (the memory store round-trips through markdown; the gates, incl. the A/B property).

## Why

The inference chain (T11b) talks to memory only through the `Kyber.Agent.MemoryPort` seam
(`retrieve/2`), and the stub retriever served it. This slice makes memory REAL: remembered facts
are entities (never written — resolutions over the delta chain, spine 2), reified to vault
markdown files (spine 7: rendering-as-lens), and a HUMAN editing a vault file is a first-class
event — observed by the watcher, attested as a `MemoryEdited` delta (`source: :human_edit`, old +
new content), and the entity's canon re-resolves to the edited content. Provenance is a ranking
axis: human edits outrank auto-derived memory in retrieval. The T11b MemoryPort determinism
clause binds HERE: the retriever MUST be a pure function of (store, query, state) — a T11c
retriever consulting wall-clock, an embedding service, or mutable state voids AC3's byte-identical
re-fire (the clause is in the T11b-claude contract, carried).

The LLM-backed PROSE summarizer is a design option, NOT this slice: the deterministic digest
checkpoint (T11b fold) remains the contract; prose summaries carry a determinism-vs-quality
tradeoff that is the user's to make. Recorded, not built.

## Deliverables (scope: `lib/kyber/agent/memory*` + `lib/kyber/agent/memory_port.ex` + `test/memory*`)

- **`Kyber.Agent.Memory`** — the memory container (gather handler + resolution authority):
  `MemoryEntity` reified as entities-as-resolutions over the delta chain (never a written entity),
  `MemoryEdited` deltas re-resolving the entity's canon; intake takes deltas unconditionally
  (spine 9), the container is a cache of truth — rehydrate by replay (spine 6).
- **`Kyber.Agent.Memory.Projector`** — MemoryEntity → vault markdown file (the rendering lens;
  the vault dir is tmp-configured, never `~/.kyber`).
- **`Kyber.Agent.Memory.Watcher`** — observes the vault dir for out-of-band edits → emits a
  signed `MemoryEdited` delta (attested, `source: :human_edit`, old + new content) → the canon
  re-resolves; the watcher ticks on demand (no `Process.sleep` — the tick is the no-sleep drive).
- **`Kyber.Agent.Memory.Tierer`** — provenance weighting: human-edited memory ranks above
  auto-derived; the ranking is a pure function of the store.
- **`Kyber.Agent.Memory.Retriever`** — the REAL `Kyber.Agent.MemoryPort` implementation: pure
  function of (store, query, state) — trajectory retrieval (the time-ordered chain of a
  memory's resolutions, oldest → newest) + provenance ranking. The A/B property (AC10): the
  T11b stub and this retriever are swappable behind the same seam against the same store.
- **`MemoryEdited` event template** in `Kyber.Agent.Events` (mirroring `MemoryEntity`'s shape).

## Acceptance criteria

_Owned by this slice (from the umbrella, verify: methods verbatim):_

- **AC6 — The memory store round-trips through markdown:** a MemoryEntity resolves → projects
  to a vault markdown file; a HUMAN EDIT to that file is observed by the watcher → a
  `MemoryEdited` delta → the entity's canon re-resolves to the edited content; the edited
  memory carries `provenance: human` and the retriever ranks it above auto-derived memory.
  **Mapped shape (deliverable finding — the closed genesis refuses a literal `source` role and
  has no old-content slot):** NEW content inline; the human marker rides the optional `reason`
  string (`"human_edit"`); OLD content rides the `edits` pointer (composites point — the
  superseded canon head's delta carries it); AUTHORITY rides the signature (the watcher signs
  with the human key; provenance derives from the signer). **EOL canonicalization rule
  (premortem C2 2026-08-06):** the watcher parses BOTH the projected canon and the file body
  through the same normalization (trailing EOLs stripped, CRLF canonicalized to LF) before
  comparing — a human save that only touches line endings mints NO edit; the stored content
  never embeds `\r` bytes. **Deletion semantics (premortem C2):** a missing file is NOT an
  edit and the next projection re-renders it (store only learns; delete-forget is a retraction
  design, out of this slice) — pinned so the surprise is documented, not silent. verify: a
  test writes a vault file, edits it out-of-band, ticks the watcher, and asserts the edit
  delta + the re-resolved canon + the provenance role; a second test saves a CRLF/trailing-EOL
  variant and asserts NO edit delta is minted.
- **AC10 — Gates:** no `Process.sleep` in test/ (send_after/assert_receive only); rails
  (deps/, spec/, SPEC.md, mix.exs, config/) frozen — rails-guard clean; the real `~/.kyber`
  never touched (tmp store/keyring/vault everywhere); format clean; warnings-as-errors clean;
  the memory store and schema container are swappable behind the same substrate (the A/B
  property: a second memory container can serve the same queries against the same store —
  NORMATIVE reading: the three-way equality test — container A == container B == the bare pure
  path, B rehydrated by replay from the same store, and identical retrieval across all three;
  named test: `test/memory_test.exs` "AC10 A/B"). verify: `grep -r "Process.sleep" test/`
  empty; rails-guard passes; `mix format --check-formatted` clean; `mix compile --force
  --warnings-as-errors` clean; the three-way equality test is in the suite.

## Carried contract (binds this slice — from the T11b-claude amendment)

- The MemoryPort determinism clause: `retrieve/2` MUST be a pure function of (query, state) —
  any time-, order-, or service-dependent retrieval voids AC3's byte-identical re-fire. The
  T11c retriever honors it by construction (trajectory + provenance are pure store reads).

## Rails (frozen, same as the siblings)

`deps/`, `spec/`, `SPEC.md`, `mix.exs`, `config/` — never touched. Tmp store/keyring/vault.

## Gate (completion — deliverable existence + suite)

`mix test` green AND `test -f` for each named deliverable (memory container, projector,
watcher, tierer, retriever). AC6's round-trip test is the slice's spine.
