# Oracle Arc Report — T11c → T13 (2026-08-07)

Comprehensive record of choices, discoveries, and verdicts for the arc from the memory
store through the associative-memory pilot. Companion to PR #4 (branch
`provisional/oracle`, base `main`, unmerged).

---

## 0. The bet under test

> **The harness elevates any model.**

Every slice was built as a blind multi-model campaign: the same contract, the same ADLC
ceremony, N vehicles (claude-code/Fable, prime-agent/K3, prime-agent/deepseek) working
independently in isolated worktrees. A blind judge (Fable) tasted the artifacts, scored
contract coverage + tests + honest reporting, and the winner was folded into
`provisional/oracle`. Losers were deleted — branches, remote refs, worktrees, tickets.

The verdict after four campaigns: **the bet holds.** The winner has been a different
vehicle every time (T11c fable, T12 k3, T13 fable), and the same vehicle that wins one
slice loses the next (Fable's four-peat broke at T12). The harness — ceremony, doctrine,
completion gates — is the constant; the model is the variable.

---

## 1. The slices

### T11c — the memory store (`3057a2f` on main, merged)

Verdict: **24–19–18, fable wins.** Three-way: fable, k3, deepseek.

Key decisions folded:
- **Entities-as-resolutions**: a memory entity is the resolution of its edit delta chain.
  Retraction is negation, merge is union, identity is content-derived — the atom is not
  renegotiable.
- **Provenance is authority, never the label**: the signer of the head edit decides the
  entity's tier (human vs agent), via the boot-known human key set. An agent-signed edit
  labelled `human_edit` is `:auto` under a known human key — the spoof-pin test pins it.
  The reason-string fallback is documented pending operator-key boot wiring.
- Three-way A/B replay, rehydrate fix, memory_test async:false (the T11c fold).

### T12 — the agent acts (`fd50a79` on provisional/oracle)

Verdict: **24–21–17.5, k3 wins — Fable's first loss.** The judge's basis: the k3 bundle
was the only one simultaneously *complete* on the contract, *uniform* across legs
(everything gated, one chain shape), and the one that made the known-flaky base suite
fully stable (0 failures ×3 — k3 and deepseek independently root-caused the same flake
family: the Schema death race, peer cap-close, application_test log).

What landed:
- **Action registry as data**: named actions with typed schemas, resolved at boot.
  Literal dotted names (`fs.read`, `sh.run`) are the contract vocabulary (deepseek's
  colon convention lost the verdict in the A/B).
- **The permission gate is the boundary**: every action — including stubs — passes the
  gate; allow/deny/refuse; fail closed; decisions attested as deltas; re-fired calls are
  answered from the store, NEVER re-executed. Store-outranks-changed-policy (a persisted
  allow decision is re-emitted even after boot policy changes) is a headline property.
- **Folds from the losers** (the blind taste test's value: every vehicle's best idea
  survives):
  - A's hard timeout → upgraded to a **process-TREE kill** (`/proc` descendants walk +
    cwd-scoped straggler sweep). WSL findings, observed and documented: group kills are
    unreliable (`kill -KILL -<pgid>` killed its own sender, exit 137) and cmdline-pattern
    sweeps can kill the test harness itself (exit -9 — the Hermes wrapper shell's cmdline
    contained the test text). `setsid` rejected (forks when the caller is a group leader,
    breaking exit_status propagation).
  - C's **symlink-aware realpath containment** (two-layer: lexical + realpath walk,
    cycle-capped 40 hops, nonexistent-tail tolerant for writes).
  - C's **refusals visible in the lens**: a denied call renders in the projection with
    the reason as result and status `refused`.
- 268 tests / 0 failures ×2. Premortem: 4H/4M/1L (carries below).

### T13 — the agent remembers (`e3f312e` on provisional/oracle)

The **planning-layer pilot**: instead of three vehicles proposing three architectures
(T12's dotted-vs-colon vocabulary, SIGKILL-vs-buffering, separate-module-vs-mode-flag),
a blind three-voice **rumble** (fable propose → k3/deepseek argue → fable synthesize)
converged on ONE plan. Then two builds (fable, deepseek) executed that same plan, and
the plan-fidelity diff was measured.

Verdict: **fable, plan-faithful on every pinned item.**
- API surface: 15/19 public signatures byte-identical; the 4 diffs cosmetic (df/2
  public-vs-private, seeds/3 bound-variable names).
- Cross-build test swap: fable's tests vs deepseek's lib → 1 failure (deepseek's
  deviation pin); deepseek's tests vs fable's lib → 2 failures (both deepseek's
  over-assertions).
- The one design-level deviation: deepseek's `ContextBuilder.window/2` returned the
  bare tail list (`|> elem(1)`) instead of the pinned `Enum.split` tuple `{dropped,
  kept}`, and its tests encoded the deviation (a strict `edges_walked` inequality its
  cap-before-expansion walk satisfies but the plan's cap-after-expansion does not).
- **Pilot conclusion: divergence collapsed from 3 architectural (T12) to 1 return-shape
  deviation (T13). The rumble is the house pattern** — proposals ≥ arguments ≥ converged
  plan; fable reserved for planning + judging, deepseek driving, k3 arguing.

What landed:
- `Assoc` + `Assoc.Index` (unified tagged-feature space: `{:target,_}`, `{:cite,_}`,
  `{:session,_}`, `{:digest,_}`; pure one-pass fold, rebuilt per retrieve) +
  `Assoc.Saturation` (the groove: window-relative prefetch, byte-identical re-fire).
- **Synchronicity is a graph property, never a truth-maker**: the divergent channel is
  entities sharing rare digests with the query but NOT directly linked — a shared
  non-query session is not direct; that is the synchronicity.
- Seeds ride the wire (seeds → resonant → divergent, deduped), precision never
  truncated, tail ≤ 4+8+2 by construction.
- Mode-flag retriever extension: state without `assoc: true` is byte-identical T11c;
  with it, `{:ok, %{memory_ids:, associations: %{seeds:, resonant:, divergent:}}}`.
- 279 tests / 0 failures. Premortem: 3H/4M/4L (carries below).

---

## 2. Carries into T14 (the reactor)

**Correction (2026-08-07, user-caught): the premortems ran post-fold as close-out formalities —
a deviation from the ADLC P1 intent (premortem BEFORE the build). The defect-class findings
were fixed PRE-MAIN-MERGE in the hardening round (commit `2cd769f`):** AC4 de-placiboed
(channel-level assertions), below_prompt → conversation_ref discipline, normalize/1 refusal,
human_author threaded into Index.build, cite-fan cap, divergent_cap ceiling, restart
determinism pinned, df-saturated + cold-start stated. Documented decisions: O(store) ×2
accepted, empty pointer tail by construction, human-tier boot wiring still pending.

The premortems are the arc's richest byproduct — every finding recorded as a carry, none
lost:

From T12's premortem (4H/4M/1L):
1. **Gate-refused calls hang the turn forever** (carried from the build): the refusal is
   attested in the store but no leg carries it back to the model — the turn never
   resumes. T14's reactor must close the loop.
2. **The `prompt` policy is a hole in the determinism clause**: who answers, when,
   whether the answer is itself a store delta, liveness bound. Mitigation: prompt
   answers are attested deltas, no-answer-within-T → refuse, answering key restricted to
   human authority.
3. **Idempotence is documented, not enforced**: the pre-persistence re-fire window
   re-executes side effects while "NEVER re-executed" stays nominally green. Mitigation:
   idempotence as a registry field + gate-level enforcement.
4. **"Bounded by construction" overclaims**: sh.run is time/byte/cwd-bounded only —
   absolute-path access, network, unbounded subprocesses out of scope; fs.read output
   uncapped; no concurrency bound. Mitigation: explicit not-contained statement, fs.read
   cap, serialized action runs.
5. **HTTP is SSRF-open by default**: allow-listing http.get permits every URL, redirect
   targets never re-validated, fetched content is untrusted input. Mitigation: boot-
   resolved URL policy + redirect re-validation.
6. **Gate policy is boot-frozen**; revocation not retroactive (store-outranks-changed-
   policy + store-only-learns). Mitigation: policy epoch/reload; revocation supersedes
   attested decisions.
7. A/B seam contract undefined; decision attestation key unattested; AC3 bound
   enumeration incomplete (fs.list, over-cap request behavior).

From T13's premortem (3H/4M/4L):
8. **AC4 is a placebo**: both machine-checked levels pass with `assoc: false` (T11c
   precision returns all heads) — the gate can't detect the associative mode being
   deleted; the recording is destroyed by on_exit rm_rf. Mitigation: neutralize
   precision in the AC4 scenario + persistent recording path.
9. **"Strictly below the prompt" is a content-equality heuristic**, not the
   conversation_ref discipline (a repeated prompt truncates to the first occurrence).
   Mitigation: drive the window from the timestamp-strict ref.
10. **Per-turn cost is O(store) twice** (precision leg + Index.build) while AC2 measures
    only walk-internal edges — "recall cost falls toward zero" is false operationally.
    Mitigation: stated O() contract + store-side precomputed projection or accepted
    linear growth.
11. **Synchronicity decays to nothing**: fixed `@max_df 2` makes the divergent channel
    monotonic in store growth. Mitigation: df-saturated fixture + steady-state contract.
12. Cold-start: fresh sessions get empty seeds → empty channels (never stated).
13. **No permission seam on memory reads**; assoc mode crosses session boundaries by
    design (a confidentiality statement is owed).
14. One-N-one-split false under engine `:window` override; divergent_cap override
    unbounded; restart determinism untested; normalize/1 crashes on third shapes;
    human_author ranks the two legs differently.

From T13's build findings (recorded, not defects):
15. **Cite-fan accumulation**: every admitted request citing a canon head adds a
    `{:cite,_}` feature; `edges_walked` grows in a live store. A df-style cap on cite
    fan-out is the future fold.
16. **The associative pointer tail is empty by construction today**: T11c precision
    recall returns ALL resolved memories, so the dedupe removes every associative head
    from the wire tail; the channels ride the `associations` map until precision is
    bounded (the design anticipates it).

---

## 3. Process discoveries (the harness's own evolution)

- **The rumble**: blind propose → blind argue → fable synthesize → the plan is appended
  to the spec as a "Design resolution" section; builds execute ONE plan; the plan-
  fidelity diff is the pilot metric. P2's argue round caught the round's sharpest flaw
  (P1's disjoint-all divergent rule made AC3's own seeding unsatisfiable) — arguments
  exist to kill plans, and they do.
- **Anonymization matters**: proposals and arguments are judged blind; P2's argument
  misidentified itself (defended P3's design as its own, critiqued its actual proposal
  as "P2") — arguments stand on merit, no re-run needed.
- **The P5 packet schema is unforgiving** (fought through this arc): `inputs` must be a
  single path string (a list crashes Node's path.resolve); `prompt` is a PATH to read,
  not inline text; a pass is dry only with ZERO findings; the transcript file must
  contain `ticket: <id>` and the revision string; the fingerprint must be re-discovered
  after every commit (error-first dry prosecute).
- **WSL process semantics** (T12): `sh -c` does not exec; the port child is its own
  process-group leader; group kills are broken; cmdline sweeps are banned; the tree kill
  + cwd-scoped sweep is the reliable form. All documented in shell.ex.
- **Hollow-test discipline**: survivors are analyzed one by one — every survivor in both
  slices was a doc/comment mutation (off-by-one in moduledoc refs, N=8→9, example array
  shrinks); 8/9 real-code kills each time.

---

## 4. State

- `main`: `3057a2f` (T11c merge). Untouched by T12/T13.
- `provisional/oracle`: `6417e61` — T12 + T13 merged, all close-out records committed.
- PR #4 open (base main, unmerged): this arc.
- Tickets: T1–T13 all archived, zero live. Daemons: k3 + deepseek sockets alive,
  idleEviction off, reusable for the next slice.
- Suite: 288 tests / 0 failures on provisional/oracle (hardening + refusal loop + flakes).
- AC4 live gate: PASSED 2026-08-07 — real kimi-k3 grounded "The relay deploy is pinned to commit `9f2ac4`." in the cross-session memory via the associative channels; recording preserved.
- Live-run discoveries (the ceremony doing its job): the T12 real-http adapter could never work under mix (code path pruned, inets/ssl unreachable — frozen rail worked around at the client); the gate-refusal-hang closed pre-merge; two flakes root-caused and fixed (daemon-lock spawn visibility, peer RST dropping the refusal status).
