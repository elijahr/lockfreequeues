# LCRQ + CAS2 analysis

## What `queue.nim` actually implements

v5's `src/lockfreequeues/queue.nim` is **LCRQ-inspired, not strict LCRQ**.
It is a segmented (linked-ring-list) MPMC queue that borrows the *shape*
of Morrison & Afek's LCRQ — fixed-size segments with `fetchAdd`-claimed
producer slots and a forward `next` link for overflow — but it does
**not** use the doubleword-CAS-on-cell primitive that defines a strict
CRQ cell.

### Structural evidence (segmented, linked, FAA-claimed)

- Segment type with `data`, `next`, `tail`, `head` and (for `ccProd == ccMulti`)
  `committed: array[S, Atomic[bool]]` flags: `src/lockfreequeues/queue.nim:150-181`.
- Producer slot reservation uses `compareExchange` on `seg.tail` (single 64-bit word),
  not a paired (seq, value) DWCAS: `src/lockfreequeues/queue.nim:1002-1007`. The
  publication step is `seg.committed[tail].store(true, moRelease)` — a second,
  separate store, not the same atomic transaction as the slot grab.
- MPMC consumer claim: `seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, ...)`
  (single word), followed by a separate `seg.committed[mySlot].load(moAcquire)`
  visibility check at `queue.nim:1186-1219`. Again two atomics, not one DWCAS.
- Segment retirement via nim-debra EBR: `retireOnCAS` / `retireOnPublish`
  at `queue.nim:1142-1147, 1077-1080, 1200-1206`. Strict LCRQ uses
  hazard-pointer / safe-memory-reclamation; v5 uses EBR — same family,
  different implementation.

### CAS2 / DWCAS evidence — none

A repository-wide search for `Atomic128`, `DWCAS`, `cmpxchg16`, `CAS2`,
`uint128`, `doubleword` across `src/` returns **zero hits**. v5 uses
only single-word `std/atomics` primitives (`compareExchange`, `fetchAdd`,
`load`, `store`). There is no Atomic128 anywhere in the tree.

### Why the committed-flag pattern exists

Strict CRQ cells encode `(seq, value)` and require DWCAS (paper §4).
Nim's `std/atomics` does not portably expose DWCAS. The committed-flag
overlay is the standard workaround: claim the slot with single-word
FAA/CAS on `tail`/`prevConsumerIdx`, then publish visibility via a
separate `moRelease` store on a per-slot bool. Sound and lock-free,
but pays an extra cache-line touch per element and cannot express
the SegmentClosed state in a single atomic — which is what the
v4.3-Task-14 `cellState` tri-state migration adds.

### Algorithm name

**"LCRQ-inspired segmented MPMC queue with per-slot committed-flag
publication overlay, using nim-debra EBR for segment reclamation."**

Implications for cellState: `{CellEmpty, CellFilled, CellClosed}:
Atomic[uint8]` is portable on single-word atomics, so the v4.3
migration does **not** require DWCAS and fits v5's portability
constraints. It is a richer encoding that enables the consumer-side
`close-CAS-on-empty` escalation pattern the boolean overlay cannot
express.

---

# v4.3-task-14 commit-by-commit port analysis

| SHA       | Kind   | Classification                  | Target in v5                       |
|-----------|--------|---------------------------------|------------------------------------|
| e60d504   | feat   | PORT_POSSIBLE_BUT_NOT_OBVIOUS   | `queue.nim` MPMC + MPSC paths      |
| 3f4c779   | feat   | PORT_POSSIBLE_BUT_NOT_OBVIOUS   | `queue.nim` MPMC pop path          |
| 027256c   | test   | PORT_RECOMMENDED (after e60d504+3f4c779) | new test file               |
| e3ffd6e   | test   | INAPPLICABLE                    | fixture for a v4-only commit boundary |
| 510ef27   | test   | PORT_RECOMMENDED                | new MPMC move-analyzer test        |
| da32689   | test   | INAPPLICABLE                    | v4 test files don't exist in v5    |
| b751bab   | docs   | PORT_RECOMMENDED                | inline comment near `queue.nim:1003` |
| 2e266a3   | docs   | PORT_RECOMMENDED                | doc-comment on `queue.nim` MPMC pop|
| 9763705   | test   | PORT_POSSIBLE_BUT_NOT_OBVIOUS   | needs v5 pin-state introspection   |

## Per-commit notes

### e60d504 — committed → cellState migration (Task 14+15)
**PORT_POSSIBLE_BUT_NOT_OBVIOUS.** v5's `queue.nim:178` still uses
`committed: array[S, Atomic[bool]]`. Migrating to
`cellState: array[S, Atomic[uint8]]` with `CellEmpty/CellFilled/CellClosed`
is portable (no DWCAS needed) and would enable the close-CAS
escalation in 3f4c779. Affected sites in v5:
producer publish at `queue.nim:1005`, MPSC consumer commit-check at
`queue.nim:1069`, MPMC consumer commit-checks at `queue.nim:1193, 1214`.
Open design question: v5 collapses MPMC and MPSC into one `Segment`
type with `when ccProd == ccMulti` for the publication field; the v4
migration was monolithic per-family. In v5 the field swap also touches
the MPSC pop site, which the v4 commit did not. Estimated work:
~50 LOC field/type rename + ~20 LOC at each of 4 access sites + new
helper `publishCell` / `tryCloseCell` (~30 LOC) + 1-2 days design to
confirm MPSC pop semantics under the tri-state (does the single
consumer ever need to observe `CellClosed`?). Total ~150 LOC + design.

### 3f4c779 — pop tryClaimSlot fetchAdd + close-CAS (Task 16)
**PORT_POSSIBLE_BUT_NOT_OBVIOUS.** Depends on e60d504 landing first.
The algorithmic change: switch MPMC consumer slot claim from
`prevConsumerIdx.compareExchange` (single CAS) to
`consumerHead.fetchAdd(1)` (FAA), then perform `close-CAS-on-empty`
when the cell is observed empty after claim. This is the canonical
LCRQ consumer pattern. v5's current `queue.nim:1216` uses
`compareExchange` on `prevConsumerIdx` — this commit would replace
that with FAA on a new `consumerHead` field (or repurpose
`prevConsumerIdx` as a FAA cursor). The close-CAS gives stronger
progress guarantees under producer-skip storms but requires the
cellState tri-state from e60d504 to encode "claimed-but-empty →
closed" without losing the empty/filled distinction. Estimated work:
~80 LOC in MPMC pop path + ~40 LOC of new typestate dispatch.

### 027256c — closure-storm tests (Task 18)
**PORT_RECOMMENDED** *after* e60d504 and 3f4c779 are ported.
The v4 test file is `tests/t_unbounded_mpmc_push_typestate.nim` which
does not exist in v5. The test *concepts* (Shape A retry on closed
cell; SegmentClosed escalation) are valuable regression tests for the
ported algorithm. Port as a new file `tests/t_unbounded_mpmc_closure_storm.nim`
~180 LOC. Cannot port until close-CAS exists in v5.

### e3ffd6e — Scenario 2 fixture repair
**INAPPLICABLE.** This is a fixture fix for a removed-SC in e60d504
inside `t_match_in_generic_context_smoke.nim`, a v4-typestate-DSL test
fixture that v5 does not carry. The bug it repaired existed only at a
v4 commit boundary.

### 510ef27 — move-analyzer test for non-copyable T (Task 19)
**PORT_RECOMMENDED.** v5 currently has no move-analyzer test for the
MPMC unbounded path (`grep -r MovePayload tests/` returned nothing).
The test concept — `=copy {.error.}` on a payload type pushed through
the MPMC pipeline — is fully applicable to v5's `queue.nim` MPMC
producer at `queue.nim:1002-1007`. Independent of the cellState
migration. Port as `tests/t_unbounded_mpmc_move_analyzer.nim` ~190 LOC.
This is the highest-value standalone port: catches a real class of
defects (silent `=copy` emission) and needs no algorithmic prerequisites.

### da32689 — drop stale committed-flag comment references
**INAPPLICABLE.** Comment-only cleanup of v4 test files that don't
exist in v5. If e60d504 is ported, v5 will need its own analogous
comment cleanup (smaller scope), but this specific patch does not apply.

### b751bab — SPMC pop fetchAdd HB-rationale comment fix
**PORT_RECOMMENDED.** Pure comment fix. v5's SPMC pop at
`queue.nim:1130-1164` does not currently use `fetchAdd` (it uses
`compareExchange` on `prevConsumerIdx`), so the *specific* comment
about fetchAdd does not map directly. However, the underlying defect
(claim that HB rides on the consumer-head atomic when it actually
rides on the committed-flag / cellState chain) is worth auditing
across v5's SPMC + MPMC pop comments at `queue.nim:1130-1219`.
Estimated ~20 LOC of comment review + edits.

### 2e266a3 — DEBRA Pin-Claim Ordering invariant doc-comment
**PORT_RECOMMENDED.** The invariant text is algorithm-agnostic and
applies to v5's MPMC and SPMC pop paths. v5 currently has scattered
references to debra pin discipline but no consolidated invariant
block. Port the 6-item form (with topology-conditional Item 6 a/b/c)
as a doc-comment header on the SPMC pop at `queue.nim:1112` and the
MPMC pop at `queue.nim:1166`. ~60 LOC of comments, no code change.

### 9763705 — explicit pin-leak assertions
**PORT_POSSIBLE_BUT_NOT_OBVIOUS.** Requires v5 to expose pin-state
introspection from nim-debra (`scope.isPinned`, handle ref-count
accessors). The v4 helper template likely depends on debra 0.7.x
introspection API; v5 uses debra 0.8.0. Confirm the test-only
accessors exist on 0.8.0, then port the helper template + add
assertions to v5's closure-storm and move-analyzer tests (once
those exist from 027256c / 510ef27 ports). ~100 LOC test helper +
assertions.

---

# Recommended action

1. **Port 510ef27 first** (MPMC move-analyzer test, INDEPENDENT). It
   has zero algorithmic prerequisites, exercises a real class of v5
   defects (silent `=copy` in the MPMC publish path at `queue.nim:1004`),
   and gives a regression net before any production change. ~1 day.

2. **Port 2e266a3 + b751bab next** (doc-comment landings, INDEPENDENT).
   Pure documentation; lands the DEBRA Pin-Claim invariant and corrects
   the HB-rationale comments on v5's SPMC/MPMC pop. ~0.5 day. Use the
   landing to audit *all* HB comments in `queue.nim:1130-1219` against
   the actual atomic ordering chain — likely surfaces 2-3 more stale
   comments.

3. **Decide on cellState migration as a v5.0.x or v5.1 design item.**
   Commits e60d504 + 3f4c779 + 027256c form an atomic algorithmic
   upgrade (close-CAS-on-empty for MPMC progress under producer-skip).
   Recommended sequence if pursued: (a) write a design doc covering
   the MPSC-pop semantics question, (b) port e60d504 (cellState
   field swap + publish/check sites), (c) port 3f4c779 (consumer
   FAA + close-CAS), (d) port 027256c as the regression net. Est.
   3-5 days end-to-end. **Do not bundle into v5.0.0** — v5.0.0 ships
   the architecture collapse; cellState is a follow-on progress-guarantee
   upgrade that wants its own design review.

4. **Skip e3ffd6e and da32689** entirely — they are v4-only commit-boundary
   artifacts with no v5 analog. If e60d504 is ported, a v5-native
   equivalent of da32689's comment cleanup will fall out of the port.

5. **Defer 9763705 until 027256c + 510ef27 are landed** — pin-leak
   assertions are only meaningful at test sites that exercise pin
   discipline; landing the tests first gives the assertions somewhere
   to live. Verify debra 0.8.0 pin-state introspection surface before
   committing to the port.
