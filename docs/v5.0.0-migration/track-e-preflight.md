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
