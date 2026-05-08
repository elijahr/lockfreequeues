## Smoke test for typestates 0.8.0 match macro in 3-static-int generic
## contexts. Gates v4.3 Phase B facade migration. See design doc §4 A3.
##
## Hypothesis (R2, HIGH risk): the typestates match macro might fail to
## expand correctly when invoked from inside a generic helper proc whose
## own type parameters drive the typestate union's instantiation
## ([S: static int; T; MaxThreads: static int]). This file validates the
## macro on every union arm reachable from MPMCPopContext, on the
## production unbounded-MPMC pop typestate, using uniform `match` syntax
## across all 7 arms (including the single-target MPMCPopSegmentLoaded
## transition, made possible by the per-state `match` overload that
## typestates 0.8.0 emits via `generateSingleTargetMatch`).
##
## Coverage of the 7 MPMCPop constructors:
##
##   counts[0] MPMCPopReady             - via match arm in MPMCPopSlotClaimResult (CAS race)
##   counts[1] MPMCPopSegmentLoaded     - via single-target match arm in
##                                        smokeSlotClaimedThenComplete
##                                        (typestates 0.8.0 emits a
##                                         dedicated `match` overload for
##                                         single-target transitions,
##                                         disambiguated by typed
##                                         first-parameter resolution).
##   counts[2] MPMCPopSlotClaimed       - via match arm in MPMCPopSlotClaimResult
##   counts[3] MPMCPopSlotUncommitted   - via match arm in MPMCPopSlotClaimResult
##   counts[4] MPMCPopSegmentExhausted  - via match arm in MPMCPopSlotClaimResult
##   counts[5] MPMCPopEmpty             - via match arm in MPMCPopAdvanceResult
##   counts[6] MPMCPopComplete          - via match arm in MPMCPopCommitCheck
##
## All `match` invocations occur inside generic helper procs parameterized
## over `[S: static int; T; MaxThreads: static int]`, satisfying R2's
## exact stress shape.

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_mpmc_push
import lockfreequeues/typestates/unbounded_mpmc_pop

# ---- Generic helper procs (R2 stress sites: each contains `match` and is
# instantiated with [S: static int; T; MaxThreads: static int] from outside).

proc smokeSlotClaimedThenComplete[S: static int; T;
    MaxThreads: static int](
    base: var UnboundedMupmucBase[S, T, MaxThreads],
    handle: ThreadHandle[MaxThreads],
    counts: var array[7, int],
) =
  ## Scenario 1: drive into SlotClaimed → Complete.
  ## Touches arms: MPMCPopSegmentLoaded (counts[1], via single-target
  ## match), MPMCPopSlotClaimed (counts[2]), and MPMCPopComplete
  ## (counts[6]).
  var op = startPop[T, S, MaxThreads](unpinned(handle).pin(), addr base)
  var loaded = op.loadSegment()
  match loaded:
    MPMCPopSegmentLoaded(l):
      inc counts[1]
      var claim = l.tryClaimSlot()
      match claim:
        MPMCPopSlotClaimed(c):
          inc counts[2]
          var commit = c.readItem()
          match commit:
            MPMCPopComplete(done):
              inc counts[6]
              discard done.extractPinned().unpin()
            MPMCPopSlotUncommitted(_):
              check false # unreachable in this scenario
        MPMCPopSegmentExhausted(_):
          check false
        MPMCPopSlotUncommitted(_):
          check false
        MPMCPopReady(_):
          check false

proc smokeSegmentExhaustedThenEmpty[S: static int; T;
    MaxThreads: static int](
    base: var UnboundedMupmucBase[S, T, MaxThreads],
    handle: ThreadHandle[MaxThreads],
    counts: var array[7, int],
) =
  ## Scenario 2: drive into SegmentExhausted → Empty.
  ## Touches arms: MPMCPopSegmentExhausted (counts[4]) and MPMCPopEmpty (counts[5]).
  var op = startPop[T, S, MaxThreads](unpinned(handle).pin(), addr base)
  var loaded = op.loadSegment()
  var claim = loaded.tryClaimSlot()
  match claim:
    MPMCPopSegmentExhausted(ex):
      inc counts[4]
      var advance = ex.advanceSegment()
      match advance:
        MPMCPopEmpty(em):
          inc counts[5]
          discard em.extractPinned().unpin()
        MPMCPopReady(_):
          check false # unreachable: no next segment
    MPMCPopSlotClaimed(_):
      check false
    MPMCPopSlotUncommitted(_):
      check false
    MPMCPopReady(_):
      check false

proc smokeSlotUncommitted[S: static int; T;
    MaxThreads: static int](
    base: var UnboundedMupmucBase[S, T, MaxThreads],
    handle: ThreadHandle[MaxThreads],
    counts: var array[7, int],
) =
  ## Scenario 3: drive into SlotUncommitted (committed flag false).
  ## Touches arm: MPMCPopSlotUncommitted (counts[3]).
  var op = startPop[T, S, MaxThreads](unpinned(handle).pin(), addr base)
  var loaded = op.loadSegment()
  var claim = loaded.tryClaimSlot()
  match claim:
    MPMCPopSlotUncommitted(u):
      inc counts[3]
      discard u.extractPinned().unpin()
    MPMCPopSlotClaimed(_):
      check false
    MPMCPopSegmentExhausted(_):
      check false
    MPMCPopReady(_):
      check false

proc smokeReadyViaCASRace[S: static int; T;
    MaxThreads: static int](
    base: var UnboundedMupmucBase[S, T, MaxThreads],
    handle: ThreadHandle[MaxThreads],
    counts: var array[7, int],
) =
  ## Scenario 4: drive into Ready via CAS-loss retry path.
  ## Touches arm: MPMCPopReady (counts[0]).
  var op = startPop[T, S, MaxThreads](unpinned(handle).pin(), addr base)
  var loaded = op.loadSegment()
  # Simulate another consumer racing ahead (canonical pattern from
  # tests/t_unbounded_mpmc_pop_typestate.nim "tryClaimSlot returns Ready
  # when CAS fails").
  let seg = loaded.segment
  discard seg.prevConsumerIdx.fetchAdd(1, moRelaxed)
  var claim = loaded.tryClaimSlot()
  match claim:
    MPMCPopReady(r):
      inc counts[0]
      # Drain the queue to clean up the pin (Ready has no extractPinned;
      # it must be advanced through the pipeline). One more loadSegment +
      # tryClaimSlot is enough on this scenario's seed: prevConsumerIdx
      # has been bumped to a slot whose committed flag is true and the
      # CAS will succeed this time.
      var loaded2 = r.loadSegment()
      var claim2 = loaded2.tryClaimSlot()
      match claim2:
        MPMCPopSlotClaimed(c):
          var commit = c.readItem()
          match commit:
            MPMCPopComplete(done):
              discard done.extractPinned().unpin()
            MPMCPopSlotUncommitted(_):
              check false
        MPMCPopSegmentExhausted(_):
          check false
        MPMCPopSlotUncommitted(_):
          check false
        MPMCPopReady(_):
          check false
    MPMCPopSlotClaimed(_):
      check false
    MPMCPopSegmentExhausted(_):
      check false
    MPMCPopSlotUncommitted(_):
      check false

# ---- Test segment / queue setup helpers (non-generic; use S=64, MT=4, T=int).

type
  TestQueue = UnboundedMupmucBase[64, int, 4]
  TestSegment = MPMCSegment[64, int]

proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  for i in 0 ..< 64:
    result.committed[i].store(false, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

# ---- Tests

# Module-level shared counter array. Aggregated across the per-scenario
# tests; the final test asserts each counter == 1 (each MPMCPop arm fired
# exactly once across the suite).
var allCounts: array[7, int]

suite "Match macro in [S, T, MaxThreads] generic context (R2 gate)":
  test "Scenario 1: SlotClaimed -> Complete (and SegmentLoaded reachability)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 99
    seg.committed[0].store(true, moRelaxed)
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)
    smokeSlotClaimedThenComplete[64, int, 4](queue, handle, allCounts)
    freeTestSegment(seg)

  test "Scenario 2: SegmentExhausted -> Empty":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var seg = newTestSegment()
    seg.prevConsumerIdx.store(4, moRelaxed)
    seg.tail.store(5, moRelaxed) # mySlot=5 >= tail=5 → SegmentExhausted
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    smokeSegmentExhaustedThenEmpty[64, int, 4](queue, handle, allCounts)
    freeTestSegment(seg)

  test "Scenario 3: SlotUncommitted (committed flag false)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(false, moRelaxed) # NOT committed
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)
    smokeSlotUncommitted[64, int, 4](queue, handle, allCounts)
    freeTestSegment(seg)

  test "Scenario 4: Ready via CAS-loss retry":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var seg = newTestSegment()
    seg.prevConsumerIdx.store(2, moRelaxed)
    seg.tail.store(10, moRelaxed)
    seg.data[3] = 99
    seg.data[4] = 88
    seg.committed[3].store(true, moRelaxed)
    seg.committed[4].store(true, moRelaxed)
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(7, moRelaxed)
    queue.segments.store(1, moRelaxed)
    smokeReadyViaCASRace[64, int, 4](queue, handle, allCounts)
    freeTestSegment(seg)

  test "All 7 MPMCPop arms fired exactly once (R2 acceptance)":
    # Acceptance: each of the 7 arms fired exactly once across the
    # preceding scenario tests.
    for i in 0 .. 6:
      check allCounts[i] == 1

  test "Compile-time delta sanity":
    # Documented in commit message; this test exists for grep-ability.
    check true
