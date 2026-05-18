# Track E Preflight Memo — M3 Semantics Preservation

## Mandate to Track E Manager

The fixes captured below MUST be preserved (in semantics, not necessarily in
code shape) during the unified-Queue rewrite under rkEbr × ccMulti ×
unbounded paths. Both surfaced via Phase 4.7 lychee audit (M3) as
v4.3-no-post-release-deferral items. Track E Manager pre-flight checklist
must include verification that these semantics are reflected in the rkEbr
code paths. Failure to preserve is a HALT-GATE surface for Track E.

## Provenance

- `3f4c779` (feat/v4.3-task-14) — Task 16 / D5/D7/C6/E1
- `b751bab` (feat/v4.3-task-14) — F3 SPMC-analog of `e60d504`
- Both orphan on feat/v4.3-task-14; never merged to devel or v5.0.0-impl.
  See Phase 4.7 audit (lychee M3) for verification methodology.

## Fix 1 — 3f4c779: Pop tryClaimSlot fetchAdd + close-CAS (MPMC)

Substance:

- Pre-claim short-circuits in MPMC pop `tryClaimSlot`:
  - **SC1** (Doc C §3 D7): `consumerHead >= S` → `UMPMCPopSegmentExhausted`.
  - **SC2** (Doc C §3 D5/C6 + §7.4): paired `moAcquire` on
    `seg.closed.load(moAcquire)` AND `seg.tail.load(moAcquire)`; on
    `closed && consumerHead >= tail` → exhausted. **C6 is load-bearing** —
    the `tail` acquire is needed even though it is argumentatively-sufficient
    via the closed-load HB chain through E9.
- Claim: `seg.consumerHead.fetchAdd(1, moAcquire)`; `mySlot >= S` →
  exhausted (D7 dead-code-equivalent; defense-in-depth assertion guards
  regression).
- Close-CAS on observed-empty:

  ```nim
  cellState[mySlot].compareExchange(
    CellEmpty, CellClosed, moAcquireRelease, moAcquire)
  ```

  - Success → `UMPMCPopClosedSlot` (TYPE-ONLY state defined at Task 14
    becomes emittable here).
  - Failure → `doAssert(expected == CellFilled)` + `UMPMCPopSlotClaimed`.
  - **C16**: `doAssert` proves `CellClosed`-on-failure impossible (consumer
    `fetchAdd` returns unique `mySlot`; no peer consumer can close it).
  - **C17**: producer's `writeItem` only writes `CellFilled` via publish-CAS;
    `CellClosed` is consumer-only state under LCRQ.
- HB chain (Doc C §7.1 E1): close-CAS success-AcqRel pairs with producer's
  prior `moRelease` publish-CAS on `cellState`.

**Track E mandate for this fix:** the unified-Queue rkEbr × ccMulti pop path
MUST implement these pre-claim short-circuits and close-CAS semantics;
reviewer should be able to cite SC1/SC2/C16/C17 against the rewrite.

## Fix 2 — b751bab: SPMC fetchAdd HB-rationale (docs/comment)

Substance:

- SPMC `fetchAdd` HB-rationale comment was a copy-paste from a
  multi-consumer context with two defects:
  1. SPMC is single-consumer by design — no "other consumers" for the RMW
     to pair with. The `fetchAdd` is uncontended.
  2. `seg.data` publication HB does NOT ride on `consumerHead`. Post-Task-11
     LCRQ migration, `seg.data` publication rides on the `cellState` CAS
     chain (Doc C §7.1 E1).
- F3-analog of `e60d504`'s MPMC inline fix.

**Track E mandate for this fix:** under the unified Queue rewrite, any
rkEbr × ccSingle × unbounded path that retains a `fetchAdd` claim primitive
on `consumerHead` MUST have the HB-rationale comment reflect: (a)
single-consumer/uncontended `fetchAdd`; (b) `cellState` CAS chain as the
actual `seg.data` HB path.

## Verification methodology (Phase 4.7 lychee M3)

- `git log 9cde893 -- src/lockfreequeues/typestates/unbounded_mpmc_pop.nim`
  returns only `70d4fcc` (Release 3.2.0); zero Task-16 keywords present.
- `git log 9cde893 -- src/lockfreequeues/typestates/unbounded_spmc_pop.nim`
  returns only `70d4fcc`; the `fetchAdd`-claim code path on which `b751bab`
  operates does not exist on v5.0.0-impl (231-line file, post-Task-11
  additions absent).
- Merge base `git merge-base 3f4c779 9cde893` = `b6da7f6` (devel HEAD;
  v5.0.0-impl base). `3f4c779` depends on Tasks 11-15 chain
  (`b7f2338` + `848d6f8` + `e60d504`) absent from devel and v5.0.0-impl.
- Conclusion: both commits orphan; cherry-pick not isolable; semantics
  preserved here for Track E to absorb during the unified-Queue rewrite.

## Doc C cross-references

- §3 D5/D7 — pre-claim short-circuit invariants
- §3 C6 — paired-acquire load-bearing rationale (tail + closed)
- §3 C16/C17 — close-CAS expected-value invariants
- §7.1 E1 — cellState-CAS HB chain for `seg.data` publication
- §7.4 SC2 — exhausted-on-closed short-circuit detailed ordering analysis

## Broader v4.3 Substantive Work (Phase 4.7 SOFT FLAG resolution)

Beyond the M3 fixes (3f4c779, b751bab) captured in the "Fix 1" + "Fix 2"
sections above, the Phase 4.7 prep audit (Manager-Item1 CHANGELOG-rewrite
verification) identified additional v4.3 substantive work absent from
feat/v5.0.0-impl. The work was developed on feat/v4.3-task-14 (orphan
branch, never merged to devel). Track E Manager mandate extends to all
of the below. Failure to preserve any item is a HALT-GATE surface for
Track E.

### TOCTOU correctness fixes

- `bb50bc9` (feat/v4.3-task-14): `fix(unbounded-spmc): close item-loss
  livelock in pop`
  Substance: closes a TOCTOU race in unbounded SPMC pop where the
  consumer could advance `headSegment` past a segment whose tail the
  producer was still publishing. Two coordinated fixes — (a)
  `tryClaimSlot` re-loads `seg.tail` with `moAcquire` before declaring
  SegmentExhausted on a stale snapshot; (b) the sipmuc pop facade
  acquire-loads `oldSeg.prevConsumerIdx` before the headSegment-advance
  CAS, backing off and restarting the claim loop when items remain
  unclaimed.
- `7296240` (feat/v4.3-task-14): `fix(unbounded-spsc-mpsc): close
  TOCTOU item-loss livelock in pop`
  Substance: mirrors the SPMC fix shape from `bb50bc9` across SPSC and
  MPSC topologies. Two race windows (Window A — `checkSlot`,
  Window B — segment-advance commit), both defended at the verb level
  by re-loading `seg.tail` with `moAcquire` before declaring
  SegmentExhausted and synchronising-with the producer's release-store
  on `tail`.
- Both load-bearing for unbounded correctness; semantics MUST be
  preserved during rkEbr × ccMulti × unbounded rewrite.

### Backoff infrastructure split

- `backoffOnCASLossRetry` split (from `backoffOnRetry`):
  Source SHA `4153554` (feat/v4.3-task-14):
  `perf(backoff): split path-typed backoff; CAS-loss-retry sites stop
  yielding`. Intent: introduce `backoffOnCASLossRetry()` alongside
  `backoffOnPeerWait()` in `backoff.nim` and re-attribute 11
  `backoffOnRetry(spins)` call sites across sipmuc/mupsic/mupmuc and
  unbounded_{mupsic,sipmuc,mupmuc} per design doc §3 Item 1. Helpers
  byte-identical today; the rationale for two names is semantic intent
  and grep-ability for future divergence.
- Track E mandate: rkEbr × ccMulti × unbounded paths under unified
  Queue may need a distinct CAS-loss retry backoff vs the general
  peer-wait backoff. Re-introduce or absorb into unified backoff
  module under Queue parameters.

### Bench harness toggles

- `LFQ_BENCH_HARNESS_BACKOFF` env var:
  Source SHA `3e191b3` (feat/v4.3-task-14): `feat(bench): add
  LFQ_BENCH_HARNESS_BACKOFF=0 runtime toggle`. Intent:
  `HarnessBackoff.backoff` early-returns when
  `LFQ_BENCH_HARNESS_BACKOFF=0` is set at process start, cached at
  module init via top-level `let` (no getEnv cost in the bench hot
  path). Enables falsifiable validation that queue-side path-typed
  backoff fix is sufficient without the harness safety net (design
  doc §3 Item 4).
- Track E mandate: if the env-toggle is preserved as bench-harness
  mechanism, Track E rkEbr bench paths must rewire it. If reframed
  as a fixed harness behavior, document the deletion rationale.

### nimble static checks

- `lockfreeCheck`: introduced in `0147a4a` (feat/v4.3-task-14):
  `test(ci): wire orphan tests into CI; close coverage gap from
  v3.2.0`. Intent: new invariant gate that enforces lock-free type
  enforcement; wired into `nimble test` and serves as the umbrella
  nimble task that orchestrates the below static checks under a
  single entry point.
- `checkConsumerHeadsAbsent`: introduced in `1f0bd7b`
  (feat/v4.3-task-14): `refactor(unbounded): migrate sipmuc to
  facade-over-typestate-verbs`. Intent: static check that the dead
  `consumerHeads` array is absent from the unbounded sipmuc surface
  after the facade migration drops it; wired into `nimble test` to
  prevent regression.
- `checkBulkOutsidePin`: introduced in `fd20eec` (feat/v4.3-task-14):
  `refactor(unbounded): migrate mupsic to facade-over-typestate-verbs`.
  Intent: static check that bulk operations are not nested inside
  `withPin` scopes, addressing the DEBRA pin-leak vector identified
  during the mupsic facade migration.
- Track E mandate: each static check has a Doc C invariant
  counterpart. Track E must re-introduce or re-implement against
  unified Queue surface.

### Test coverage — 14 orphan tests wired

Source SHA `0147a4a` (feat/v4.3-task-14): `test(ci): wire orphan
tests into CI; close coverage gap from v3.2.0`. Brings 14
previously-orphan test files into `nimble test` / `nimble stresstest`
matrices; raises test count 268 → 340 (+72 tests).

- `tests/t_atomic_loaders.nim` — atomic loader primitives
- `tests/t_fullness_checks.nim` — storage fullness predicates
- `tests/t_mpmc_cell.nim` — MPMC cell state machine
- `tests/t_slot_seq_n.nim` — slot sequence counter (N variant)
- `tests/t_storage_n.nim` — storage (N variant)
- `tests/t_storage_n1.nim` — storage (N+1 variant)
- `tests/t_virtual_values_n.nim` — virtual values (N variant)
- `tests/t_virtual_values_n1.nim` — virtual values (N+1 variant)
- `tests/t_cas.nim` — typestate CAS primitive
- `tests/t_typestates_import.nim` — typestates module import surface
- `tests/t_match_in_generic_context_smoke.nim` — match-macro generic
  context smoke (44 `MPMCPop*` → `UMPMCPop*` migrations + 4 plain-ptr
  → `.store(seg, moRelaxed)` conversions applied)
- `tests/t_unbounded_sipsic_lockfree_types.nim` — lock-free type
  validation for unbounded sipsic
- `tests/t_mupmuc_threaded.nim` — re-enabled (formerly disabled with
  deadlock comment; resolved by `eac1d49` Vyukov per-slot sequence
  counters replacing the legacy committed-flag protocol)
- `tests/t_sipmuc_threaded.nim` — re-enabled (same `eac1d49`
  resolution)

Track E mandate: all listed tests must be re-wired under unified
Queue rkEbr × ccMulti × unbounded paths; tests that exercised
consumerHeads/closed/cellState/E1-HB invariants are PRIORITY for
Track E to absorb before claiming green.

### Refactors

- SPMC `consumerHeads` removal: source SHA `1f0bd7b`
  (feat/v4.3-task-14): `refactor(unbounded): migrate sipmuc to
  facade-over-typestate-verbs`. Drops the dead `consumerHeads` array
  from the unbounded sipmuc surface as part of the facade-over-
  typestate-verbs migration, and gates its absence with the new
  `checkConsumerHeadsAbsent` nimble task.
- `prevConsumerIdx` → `consumerHead` rename: source SHA `848d6f8`
  (feat/v4.3-task-14): `refactor(unbounded): rename prevConsumerIdx
  -> consumerHead (Task 11 LCRQ baseline)`. Cross-reference: CHANGELOG
  L5 verdict at d6ab6fd treats this rename as load-bearing for the
  LCRQ baseline established in Task 11.

### Dependency uplifts

- `typestates` 0.7.2 → 0.9.0:
  Current state: `lockfreequeues.nimble` line 14 still pins
  `typestates >= 0.7.2` on feat/v5.0.0-impl. v4.3 work bumped to
  `>= 0.8.0` via SHA `2f00ac7` (feat/v4.3-task-14): `chore: require
  typestates >= 0.8.0`. v5.0.0 wave ships 0.9.0 per the guava current
  ship target.
- Track E mandate: rebase `lockfreequeues.nimble` to `typestates
  >= 0.9.0` + verify no API drift in usage sites (the `buildMatchCase`
  generic-context bug — fixed upstream in 0.7.1 — must remain
  non-issue; verify pattern syntax compatible with 0.9.0).
