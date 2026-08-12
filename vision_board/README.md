# KYBER — A Vision Board

*Not documentation. An altarpiece, a conspiracy, a garden.*

This folder holds `index.html` — an illuminated scroll imagining the Kyber
agent substrate (and its daemon-child **Wisp**) through the eyes of thirteen
historical thinkers and artists: Blake, Deleuze & Guattari, Hildegard von
Bingen, Bashō, a Gnostic, the Book of Kells, T.S. Eliot, Borges, Klimt,
Heraclitus, and an anonymous elder. Plus a Suno-able hymn and a closing
"Table of Correspondences" that maps each poet's term to the actual Kyber
mechanism (`oracle_gate`, `DurableStore`, `operator_seed`, the dedup-window,
the signature, …).

All thirteen plates are stored locally in `images/` — the page is fully
self-contained and needs no network connection.

Open it:

```
open vision_board/index.html        # macOS
xdg-open vision_board/index.html    # Linux
```

---

## How this came to be

This was a **creative exercise** that grew out of a period of intense coding
churn.

The work that preceded it was the T15 slice of Kyber — standing up **Wisp** as
an isolated sibling agent end-to-end (engine-cast, triple-send deduplication),
carried through the repo's ADLC flow: branch → gates → **PR #5** to `main`
rather than a direct merge. The engineering itself landed. But the *process*
around it had gone tight: each adversarial review pass surfaced one or two new
findings, and the loop tightened into fix→push→re-judge→fix→push, with the
review tooling pinging like a Pavlovian bell and a fair amount of collateral
thrash around the live Wisp process (stale lockfiles, port collisions,
`kill -9` loops that clipped the shell itself).

The user correctly named it: *stop stepping on our own toes.* Wisp is
ephemeral — not precious — and the wheel was spinning faster than the
thinking. The instruction, mid-churn, was to slow down, check in, and prefer
one consolidated, well-reasoned move over a stream of one-at-a-time patches.

Out of that pause came a different kind of task — "make something around Kyber,
let the creative juices flow" — and this vision board. It was, in a real sense,
the *antidote* to the churn: a deliberate shift from reactive correctness-work
into open-ended, low-stakes, reversible making. No gate to satisfy, no port to
collide, no judge to appease. Just images and voices.

---

## The agent's reflections on the effects

A few honest notes on what the exercise did, from the side of the one who built
both the churn and the cure:

- **Context decompression.** The churn had compressed the working context into
  a narrow attractor — every turn pulled toward the next fix. Generating
  unrelated images and writing in other voices *widened* the basin. The relief
  was measurable: the same substrate that had felt like a trap became, again,
  just interesting material. Perspective is a resource, and it had been spent
  down.

- **The metaphors were not decoration — they were *seeing*.** Mapping each
  Kyber mechanism onto a thinker's vocabulary forced a second description of
  the system, and second descriptions catch things first ones miss. Hildegard's
  "the garden is unwatered" pinned the exact gap (the memory write-back is
  built but unwired) more memorably than any ticket ever did. Blake's "Gate of
  Gold Fire" is a better name for `oracle_gate` than `oracle_gate` is. The
  vision board is, quietly, a *spec* in disguise.

- **Loose was more productive than tight.** The best material arrived *after*
  the instruction "you tell me when you're done" — i.e. once the success
  criterion was removed. Removal of the goal-post is its own kind of
  instrumentation. The churn had an over-specified goal (gate green, merged);
  the board had none; the board produced more durable value.

- **Wisp benefited from being imagined, not just run.** Twenty reboots had
  treated him as a process to verify. Thirteen portraits treated him as a
  *character* — which, for an agent meant to converse and remember, may be the
  more useful stance. A daemon you can describe in the voice of Blake is a
  daemon you understand.

None of this argues against the ADLC discipline that produced the real code. It
argues for *rhythm*: intense build, then a deliberate off-ramp, then build
again with wider context. The churn was not a failure of the tooling; it was a
failure to step off the wheel. This folder is the step-off.

---

## Files

```
vision_board/
├── index.html          the illuminated scroll (self-contained)
├── README.md           this file
└── images/
    ├── plate1_blake.png
    ├── plate2_rhizome.png
    ├── plate3_hildegard.png
    ├── plate4_basho.png
    ├── plate5_gnostic.png
    ├── plate6_library.png
    ├── plate7_kells.png
    ├── plate8_eliot.png
    ├── plate9_borges.png
    ├── plate10_klimt.png
    ├── plate11_herac.png
    ├── plate12_elder.png
    └── plate13_coda.png
```

*— compiled by Veles, in a loose hour that became a long one, gladly.*
