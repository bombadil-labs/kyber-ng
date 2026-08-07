# T13 — The Agent Remembers: associative memory (claude fork)

Rev 1 — fork of the shared T13 arc contract for the claude leg of the TWO-WAY blind build (T13
rematch 2026-08-06, the planning-layer pilot: both builds implement the SAME converged plan
from the three-voice rumble). Same contract + design resolution as the shared spec; amendments
to THIS file only.

Original shared spec follows verbatim.

# T13 — The Agent Remembers: associative memory, trajectory as a walk

Rev 1 — arc ticket of the ORACLE ARC (user mandate 2026-08-06; PLAN.md §0). Builds on T11c
(the memory store: entities-as-resolutions, MemoryEdited, provenance as authority) and T12
(real actions whose outcomes the store learns). T13 makes the agent's memory OPERATIONAL: the
retriever stops scrolling and starts WALKING.

## Why

T11c's retriever does trajectory + provenance ranking — a scroll along one axis. Human memory
is associative: one thing evokes another along shared features, and the value is in the
connections the query did not name. The user's mandate (2026-08-06 musing, pinned in PLAN.md):
**walk, don't scroll** — retrieval as a semantic walk over the entity graph (the RhizomeDB
flight-lines made concrete); **groove = saturation** — the context builder pre-fetches the
association set for the current window so recall cost falls toward zero as the session deepens;
**synchronicity's kernel** — a bounded divergent-recall channel surfacing entities with
surprising shared-feature overlap despite no direct link. The constraint that makes it
sensible: association is a retrieval POLICY, never a truth-maker; the canon stays the canon.

## Deliverables (scope: `lib/kyber/agent/memory/assoc*` + retriever extension + `test/memory_assoc*`)

- **`Kyber.Agent.Memory.Assoc`** — the pure walk: from a seed set of resolved entities (the
  query's targets), follow pointer edges (shared targets, shared roles, shared sessions,
  shared content-feature hashes) up to bounded depth, collecting neighbors; returns
  `{resonant, divergent}` — resonant = neighbors with direct edges (relevance), divergent =
  the capped anomaly channel (shared-feature overlap beyond the obvious, no direct link).
  Pure structural association ONLY: every edge is a deterministic store read; NO embedding
  service, NO wall-clock (the T11b determinism clause — an embedding-backed semantic layer
  stays a documented boot-boundary swap).
- **`Kyber.Agent.Memory.Assoc.Saturation`** — the groove mechanism: the context builder
  pre-fetches the association set for the current window into the NEXT request (the lens
  becomes a resonance field); recall cost falls toward zero as the session deepens. The
  pre-fetch is a pure function of the store + the window — byte-identical re-fire holds.
- **Retriever extension** — `retrieve/2` gains the associative mode: precision recall (the
  T11c path, unchanged) + a bounded `associations` key (resonant + divergent, capped) in the
  result; the divergent channel is capped so it can never drown precision recall.
- **`Kyber.Agent.Memory.Assoc.Index`** — the derived edge index (shared targets/roles/
  sessions/content-feature hashes → neighbor sets), rebuilt deterministically from the store
  (a pure fold — no incremental cache, no orphan parking; the T11c verdict's rejection of C's
  machinery binds here).

## Acceptance criteria

- **AC1 — The walk is pure and bounded:** association is a pure function of (store, query,
  state) — deterministic re-fire byte-identical; the walk respects max depth and max
  candidates; content-feature edges come from SHA-256 digests of the content (the fold's
  digest discipline), never from prose matching. verify: the walk test asserts determinism
  (same store+query → same association set, twice), bound enforcement, and digest-based
  edges.
- **AC2 — Groove is saturation:** after N exchanges in a session, the context builder's
  pre-fetch saturates: the NEXT request carries the association set for the window (the
  `associations` key), and recall cost (edges walked) does not grow with session length —
  the per-turn cost is flat after saturation. verify: the saturation test drives a long
  session and asserts the pre-fetched set is present and the walked-edge count is flat.
- **AC3 — Synchronicity is a graph property:** the divergent channel surfaces an entity that
  shares a surprising number of features with the current context despite NO direct link —
  the cross-session "meaningful coincidence", deterministic and testable. verify: the
  synchronicity test seeds two sessions sharing an entity and asserts the divergent channel
  of a query in session A includes the cross-session entity (bounded: the channel is capped,
  precision recall unchanged).
- **AC4 — The operational run (THE gate):** Hermes boots the daemon on a tmp store/keyring
  with a REAL model; two sessions are seeded with related memories; the agent is asked in
  session B a question whose answer lives in session A's memory; the retriever's associative
  mode surfaces the cross-session memory and the model's answer grounds in it (context
  property asserted; answer-groundedness is a live-run observation, per the T11b C2 fix).
  verify: the recorded operational run with the real model.
- **AC10 — Gates (carried):** no `Process.sleep` in test/; rails frozen; tmp everywhere;
  format clean; warnings-as-errors clean; the associative retriever and the T11c retriever
  are A/B-swappable behind the same seam (the T11c three-way equality test pattern).
  verify: the carried greps + rails-guard + the A/B test.

## Carried contract (binds this slice)

- The determinism clause (T11b): retrieve/2 pure — the walk is structural edges only;
  embedding-backed semantics = boot-boundary swap, documented, never in the re-fire path.
- Association is a policy, never a truth-maker (the PLAN.md caution): resonance-ranked recall
  returns REAL entities (the canon's claims) — the walk never fabricates; the model may
  over-read an association, and the provenance/confidence of what is surfaced rides the
  result (the T11c provenance-as-authority rule).
- The T11c rejections bind: no incremental cache with orphan parking, no arbitrary hop caps
  where a pure fold suffices, no silent normalization.

## Rails (frozen, carried)

`deps/`, `spec/`, `SPEC.md`, `mix.exs`, `config/` — never touched. Tmp store/keyring/vault.

## Gate (completion — deliverable existence + suite)

`mix test` green AND `test -f` for each named deliverable (Assoc, Saturation, Index,
retriever extension). AC1's determinism test and AC3's synchronicity test are the slice's spine.

## Design resolution (converged plan, rumble 2026-08-06)

Voices: P1 = fable, P2 = k3, P3 = deepseek. Each pin names its source. The genesis schema is
frozen — there is no association pointer role, so associations ride `memoryPointers`
(P2's contradiction note, recorded: fold-in chosen; schema growth rejected as rails).

### Files (existence gate)
- `lib/kyber/agent/memory/assoc.ex` (`Kyber.Agent.Memory.Assoc`), `assoc/index.ex`, `assoc/saturation.ex`
- edited: `memory/retriever.ex` (mode flag), `context_builder.ex` (`normalize/1` + `window/2`),
  `engine.ex` (`build_messages/4` delegates its window split to `ContextBuilder.window/2` — one
  mechanical line, behavior-identical, existing engine tests unchanged) [P3]
- tests: `test/memory_assoc_test.exs` (AC1), `test/memory_assoc_saturation_test.exs` (AC2),
  `test/memory_assoc_synchronicity_test.exs` (AC3), `test/memory_assoc_retriever_test.exs` (AC10) [P1]

### Constants (module attributes in `Assoc`; only `@divergent_cap` boot-overridable, via retriever state key `:divergent_cap` [P1])
`@max_seeds 4` [P3] · `@max_depth 2` [all] · `@max_candidates 32` [P1+P2] · `@max_resonant 8` [P3]
· `@divergent_cap 2` [P2+P3] · `@min_shared 2` [P1+P3] · `@max_df 2` (fixed constant, never
N-dependent — re-fire-stable as the store grows) [argue consensus] · window `8` (the T11b pin)

### Index [P1's unified tagged-feature space; plain map, no struct]
`Assoc.Index.build(set :: DeltaSet.t()) :: %{by_feature: %{feature => MapSet.t(entity_id)}, by_entity: %{entity_id => MapSet.t(feature)}, canons: %{entity_id => Memory.memory()}}`
`feature :: {:target, source_delta_id}` (each id in the canon's source pointers)
` | {:cite, citing_delta_id}` (delta whose memoryPointers/memoryUsed cites the entity's head)
` | {:session, session_id}` (session of each source delta) `| {:digest, hex}`.
Pure one-pass fold, rebuilt per retrieve call; no incremental cache, no orphan parking.
`df(h) = MapSet.size(by_feature[{:digest, h}])`.

### Token pipeline (exact — quoted as code) [P1's pipeline; P2's ≥4 floor kills stopwords without a list]
`content |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true) |> Enum.filter(&(byte_size(&1) >= 4)) |> Enum.uniq() |> Enum.map(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower)) |> Enum.sort()`

### Seeds [P3; no fallback branch — an untested path is where builds diverge]
`Assoc.seeds(index, %{session_id: sid, prompt: p}, window_contents :: [String.t()]) :: [entity_id]`
= entities carrying `{:session, sid}` sharing ≥ 1 digest with digests(p) ∪ digests(window_contents);
rank by `{-shared_digest_count, Tierer.tier(prov), -timestamp, entity_id}`; take `@max_seeds`.
Empty seeds ⇒ empty channels.

### Walk
`Assoc.walk(index, seeds :: [entity_id], query_digests :: [hex], opts \\ []) :: %{resonant: [entity_id], divergent: [entity_id], edges_walked: non_neg_integer()}`
BFS, depth ≤ `@max_depth`; per depth: neighbors = ∪ `by_feature[f]` over f ∈ `by_entity` of the
frontier, minus visited; next frontier = top `@max_candidates` by the sort tuple.
`edges_walked += MapSet.size(by_feature[f])` for every feature expanded [P1's instrumented walk].
**Direct link is query-relative** [P3's rule; P1's disjoint-all rule makes AC3 unsatisfiable]:
e↔s direct iff shared `{:target,_}` or `{:cite,_}` feature, or both carry `{:session, query_session}`.
A shared NON-query session is NOT direct — that is the synchronicity.
`structural_edges(e) = |{s ∈ seeds : direct(e, s)}|`; `shared_digests(e) = |digests(e) ∩ (query_digests ∪ ⋃ digests(seeds))|`.
Sort tuple (Elixir ascending; T11c total order as tail, no weights) [P3, stolen by all]:
`{-structural_edges(e), -shared_digests(e), Tierer.tier(provenance(e)), -timestamp(e), entity_id(e)}`
**resonant** = candidates with `structural_edges ≥ 1`, sorted, take `@max_resonant`.
**divergent** = candidates with `structural_edges == 0` and `rare_shared(e) ≥ @min_shared`, where
`rare_shared(e) = |{h ∈ shared digests : df(h) ≤ @max_df}|` [P2's df filter, constant-ized];
sorted by `{-rare_shared, Tierer.tier, -timestamp, entity_id}`; take `@divergent_cap`.

### Saturation (groove) — integration point is `retrieve/2`, zero engine emission change [P1]; one window helper [P3]
`ContextBuilder.window(turns, n \\ 8)` = the exact `Enum.split(turns, max(length(turns) - n, 0))`
tail extracted from `build_messages/4`; engine and Saturation both call it (one N, one split).
`Assoc.Saturation.prefetch(set, session_id, prompt, opts \\ []) :: %{seeds: [head_id], resonant: [head_id], divergent: [head_id], edges_walked: non_neg_integer()}`
= build index; window_contents = `window(ContextBuilder.conversation(set, session_id), 8)` —
turns strictly below the prompt (conversation_ref discipline); seeds; walk; map entity ids →
canon heads via `canons`. Pure function of (store, window) ⇒ byte-identical re-fire; seeds
derive ONLY from the bounded window ⇒ `edges_walked` flat after saturation.

### Retriever extension (mode flag in the T11c module — the contract's "retrieve/2 gains the associative mode") [P1+P2; P3's `AssocRetriever` rejected: a second pipeline is copied code]
State without `assoc: true` ⇒ byte-identical T11c: `{:ok, [head_id]}`.
State `%{store: s, assoc: true}` ⇒
`{:ok, %{memory_ids: [head_id], associations: %{seeds: [head_id], resonant: [head_id], divergent: [head_id]}}}`
(`memory_ids` = the unchanged T11c precision list; channels carry canon-HEAD ids, bare — no hit
maps; provenance rides the canon render, per T11c provenance-as-authority).
`ContextBuilder.normalize/1`: `{:ok, list}` ⇒ `%{memory_ids: list, associations: %{seeds: [], resonant: [], divergent: []}}`; the map shape passes through.
`memoryPointers = memory_ids ++ ((seeds ++ resonant ++ divergent) |> Enum.uniq() |> Enum.reject(&(&1 in memory_ids)))`
— precision never truncated, seeds ride the wire (closes P2's vanishing-seed hole), divergent
last; tail ≤ 4+8+2 by construction, so the channel can never drown precision.

### Tests
**AC1** (`memory_assoc_test.exs`): `Index.build` twice ⇒ `==`; `walk` twice ⇒ `==`; caps enforced
(frontier ≤ `@max_candidates`, depth ≤ 2); digest edges only (a token-different prose pair shares
no `{:digest,_}` feature). Fixed timestamps 1.0, 2.0, …
**AC2** (`memory_assoc_saturation_test.exs`): drive 3×8 exchanges; assert the prefetch heads
appear in the emitted request's memoryPointers and `edges_walked(turn 9) == edges_walked(turn 24)` [P1's exact assertion].
**AC3** (`memory_assoc_synchronicity_test.exs`) — fixture pinned verbatim [P3]: sessA: entity x
"aurora tide fjord" (source deltas in BOTH sessions, distinct deltas — the shared entity),
entity y "fjord kayak gear" (sessA only); sessB: entity z "aurora tide report" (sessB only).
Query `%{session_id: "sessA", prompt: "the aurora tide fjord crossing"}`. Assert: z's head ∈
divergent; z ∉ resonant; `length(divergent) <= 2`; `memory_ids` == the precision-mode result;
two runs `==`.
**AC10** (`memory_assoc_retriever_test.exs`): three-way A/B on a store WITH shareable features
[argue consensus: a no-feature fixture is vacuous]: Stub vs `%{store: s}` vs `%{store: s, assoc: true}`
— precision output byte-equal across all legs; assoc leg's divergent length in 0..2.

### AC4 live run (Hermes; recorded operational run, not in `mix test` — T11b precedent)
Tmp store/keyring/vault, real model, retriever `%{store: …, assoc: true}`. Seed sessA:
MemoryEntity "relay deploy pinned to commit 9f2ac4"; sessB: MemoryEntity "relay deploy notes".
Prompt in sessB: "what commit is the relay deploy pinned to?" [P3's strings, pinned verbatim —
an unpinned fixture was the rumble's biggest divergence risk].
Machine-checked, both levels [P3's delta assertion + P1's body-grep]:
(1) the sessB `InferenceRequested`'s memoryPointers includes sessA's canon head;
(2) the recorded request body carries a `Memory: <sessA canon content>` system message, byte-equal.
Answer-groundedness = recorded live-run observation, never asserted (T11b C2).

**Taste-test metric:** the two builds agree byte-for-byte on every pinned name, signature, result-map atom, constant, and fixture string above (≥ 90% of public module/function signatures identical), and each build's pinned test assertions pass unmodified against the other build — the judge finds only formatting/private-helper differences, no design-level divergence.

## Post-verdict amendment (2026-08-07 — plan-fidelity pilot, two-way rematch)

The rumble converged; two builds (fable, deepseek) implemented the SAME Design resolution.
Taste-test metric measured: 15/19 public signatures byte-identical (the 4 diffs: df/2 public
vs private, seeds/3 bound-var names — cosmetics); result-map atoms, constants, token pipeline,
fixture strings identical everywhere.

PILOT VERDICT: fable plan-faithful on every pinned item; deepseek deviated on ONE —
`ContextBuilder.window/2` returns the bare tail list (`|> elem(1)`) instead of the pinned
`Enum.split` tuple `{dropped, kept}` — and wrote tests encoding the deviation (a strict
`edges_walked` inequality its cap-before-expansion walk satisfies but the plan's
cap-after-expansion does not). Cross-build swap: fable's tests vs deepseek's lib → 1 failure
(the window tuple pin); deepseek's tests vs fable's lib → 2 failures (both its own
over-assertions). Fable merged; deepseek's deviation + over-assertions rejected.

Pilot conclusion: the planning layer works — T12's three ARCHITECTURAL divergences (registry
vocabulary, kill strategy, module split) collapsed to ONE return-shape deviation when both
builds executed one converged plan.

RECORDED BUILD FINDINGS (future implementers, read these):
1. Cite-fan accumulation vs AC2 flatness: every admitted InferenceRequested/ResponseDelta
   citing a canon head adds a `{:cite, delta_id}` feature to that entity. In a live store
   where emitted requests re-enter the set the retriever reads, `edges_walked` grows with
   session length — the pinned flatness assertion holds only because the AC2 driven store
   accumulates message.received turns, not emitted requests. The groove claim as spec'd is
   about seed-derivation boundedness, not total edge-fan; a df-style cap on `{:cite, _}`
   fan-out is the obvious future fold.
2. The associative pointer tail is empty by construction today: T11c precision recall
   returns ALL resolved memories, so the dedupe (`reject(&(&1 in memory_ids))`) removes every
   associative head from the wire tail. The channels' value currently rides the
   `associations` map (AC2/AC4 assertions pass because heads ARE in memoryPointers via the
   precision list). The design correctly anticipates a future bounded precision list — no
   code change made; recorded.
