# T11c — The Memory Store (claude fork)

Rev 1 — fork of the shared T11c contract for the claude leg of the three-way blind taste test (T11c rematch 2026-08-06). Same contract as its siblings; amendments to THIS file only.

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
  `MemoryEdited` delta (attested, `source: :human_edit`, old+new content) → the entity's canon
  re-resolves to the edited content; the edited memory carries `provenance: human` and the
  retriever ranks it above auto-derived memory. verify: a test writes a vault file, edits it
  out-of-band, ticks the watcher, and asserts the edit delta + the re-resolved canon + the
  provenance role.
- **AC10 — Gates:** no `Process.sleep` in test/ (send_after/assert_receive only); rails
  (deps/, spec/, SPEC.md, mix.exs, config/) frozen — rails-guard clean; the real `~/.kyber`
  never touched (tmp store/keyring/vault everywhere); format clean; warnings-as-errors clean;
  the memory store and schema container are swappable behind the same substrate (the A/B
  property: a second memory container can serve the same queries against the same store).
  verify: `grep -r "Process.sleep" test/` empty; rails-guard passes; `mix format
  --check-formatted` clean; `mix compile --force --warnings-as-errors` clean.

## Carried contract (binds this slice — from the T11b-claude amendment)

- The MemoryPort determinism clause: `retrieve/2` MUST be a pure function of (query, state) —
  any time-, order-, or service-dependent retrieval voids AC3's byte-identical re-fire. The
  T11c retriever honors it by construction (trajectory + provenance are pure store reads).

## Rails (frozen, same as the siblings)

`deps/`, `spec/`, `SPEC.md`, `mix.exs`, `config/` — never touched. Tmp store/keyring/vault.

## Gate (completion — deliverable existence + suite)

`mix test` green AND `test -f` for each named deliverable (memory container, projector,
watcher, tierer, retriever). AC6's round-trip test is the slice's spine.
