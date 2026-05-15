## Tests for unbounded SPMC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## Multiple consumers use CAS on consumerHead to coordinate.

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_spmc_push
import lockfreequeues/typestates/unbounded_spmc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedSipmucBase[64, int, 4]
  TestSegment = Segment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.consumerHead.store(-1, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "SPMC Pop Typestate":
  test "typestate types exist and are usable":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 99

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail >= loaded.consumerHead
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      USPMCPopSlotClaimed(c):
        discard c.readItem().extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads head segment and consumerHead":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(4, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.consumerHead == 4
    check loaded.tail == 10
    check loaded.segment == seg

    check loaded.segment.next.load(moRelaxed) == nil

    seg.data[5] = 77
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      USPMCPopSlotClaimed(c):
        let complete = c.readItem()
        check complete.value == 77
        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(-1, moRelaxed)
    seg.tail.store(5, moRelaxed)
    seg.data[0] = 42

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSlotClaimed(c):
        check c.slot == 0

        let complete = c.readItem()
        check complete.value == 42
        check seg.consumerHead.load(moRelaxed) == 0
        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when no items":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(4, moRelaxed)
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        var advanceResult = f.advanceSegment()

        match advanceResult:
          USPMCPopEmpty(e):
            discard e.extractPinned().unpin()
          USPMCPopReady(_):
            check false
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  # NOTE (Task 9, 2026-05-15): the prior "over-claim race
  # (awaitingTail=true)" test has been removed. Task 9 deletes the
  # `awaitingTail` discriminator on `USPMCPopSegmentExhausted`; the
  # over-claim race is the bug Task 10a's close-CAS / `USPMCPopClosedSlot`
  # arm fixes. Once Task 10a lands, a parallel test should re-cover the
  # close-CAS path (consumer wins close-CAS on an unpublished slot,
  # pop returns none(T) without advancing headSegment).

  test "readItem reads value correctly":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(-1, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.data[1] = 43
    seg.data[2] = 44

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSlotClaimed(c):
        let complete = c.readItem()

        check complete.value == 42
        check seg.consumerHead.load(moRelaxed) == 0
        check queue.itemCount.load(moRelaxed) == 2

        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "advanceSegment returns Ready when next segment exists":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    seg1.consumerHead.store(63, moRelaxed)
    seg1.tail.store(64, moRelaxed)
    seg1.next.store(seg2, moRelease)
    seg2.consumerHead.store(-1, moRelaxed)
    seg2.tail.store(3, moRelaxed)
    seg2.data[0] = 100

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg1, moRelaxed)
    queue.tailSegment = seg2
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        var advanceResult = f.advanceSegment()

        match advanceResult:
          USPMCPopReady(_):
            # Note: Unlike MPSC, SPMC doesn't update headSegment during advanceSegment
            # The consumer needs to coordinate segment advancement at a higher level
            # This test just verifies the typestate transition works correctly
            discard
          USPMCPopEmpty(_):
            check false
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg1)
    freeTestSegment(seg2)

suite "Task 11 SPMC pop ClosedSlot state":
  test "USPMCPopClosedSlot type exists with extractPinned":
    # Type-existence + extractPinned overload check (compile-time only).
    # USPMCPopClosedSlot is dead-code-pending Task 10a (no production
    # emit yet); this test is a structural witness that Task 9's
    # type-only restructure compiles.
    check declared(USPMCPopClosedSlot)
    # Verify the extractPinned overload accepts USPMCPopClosedSlot. We
    # don't construct an instance (no emit site exists yet); the
    # `compiles()` check witnesses the overload's existence.
    check compiles((
      proc () =
        var x: USPMCPopClosedSlot[int, 8, 4]
        discard extractPinned(x)
    ))

  test "USPMCPopSegmentExhausted has NO awaitingTail field":
    # Compile-time negative check: accessing `x.awaitingTail` must
    # FAIL to compile after Task 9. Before Task 9 this `compiles(...)`
    # returns true (RED); after Task 9 it returns false (GREEN).
    check not compiles((
      proc () =
        var x: USPMCPopSegmentExhausted[int, 8, 4]
        discard x.awaitingTail
    ))
