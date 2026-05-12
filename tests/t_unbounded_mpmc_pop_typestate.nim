## Tests for unbounded MPMC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## MPMC pop combines CAS coordination (like SPMC) with committed flag checking (like MPSC).

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_mpmc_push
import lockfreequeues/typestates/unbounded_mpmc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedMupmucBase[64, int, 4]
  TestSegment = UMPMCSegment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  for i in 0 ..< 64:
    result.committed[i].store(false, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "MPMC Pop Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 99
    seg.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.prevConsumerIdx == -1
    check loaded.tail >= loaded.prevConsumerIdx
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    # Clean up
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPopSlotClaimed(c):
        var readResult = c.readItem()
        match readResult:
          UMPMCPopComplete(cmp):
            discard cmp.extractPinned().unpin()
          UMPMCPopSlotUncommitted(_):
            check false
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads head segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(4, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.prevConsumerIdx == 4
    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation and VERIFY value read
    seg.data[5] = 77
    seg.committed[5].store(true, moRelaxed)

    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPopSlotClaimed(claimed):
        var commitCheck = claimed.readItem()
        match commitCheck:
          UMPMCPopComplete(c):
            check c.value == 77
            discard c.extractPinned().unpin()
          UMPMCPopSlotUncommitted(_):
            check false
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(-1, moRelaxed)
    seg.tail.store(5, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSlotClaimed(c):
        check c.slot == 0

        # Read item and VERIFY value
        var complete = c.readItem()
        match complete:
          UMPMCPopComplete(cmp):
            check cmp.value == 42
            check seg.prevConsumerIdx.load(moRelaxed) == 0
            discard cmp.extractPinned().unpin()
          UMPMCPopSlotUncommitted(_):
            check false
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when no items":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(4, moRelaxed)
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSegmentExhausted(f):
        # Try to advance - should return Empty since no next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPMCPopEmpty(e):
            # Verify queue state remains consistent
            check queue.itemCount.load(moRelaxed) == 0

            discard e.extractPinned().unpin()
          UMPMCPopReady(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns Ready when CAS fails (simulate race)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(2, moRelaxed)
    seg.tail.store(10, moRelaxed)
    seg.data[3] = 99
    seg.data[4] = 88
    seg.committed[3].store(true, moRelaxed) # Slot 3 is committed
    seg.committed[4].store(true, moRelaxed) # Slot 4 is committed

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.prevConsumerIdx == 2

    # Simulate another thread advancing prevConsumerIdx
    discard seg.prevConsumerIdx.fetchAdd(1, moRelaxed) # Now 3

    # tryClaimSlot should detect CAS failure and return Ready
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPopReady(r):
        # Clean up - do a successful operation (3-level nested match per §3.3)
        var claimResult2 = r.loadSegment().tryClaimSlot()
        match claimResult2:
          UMPMCPopSlotClaimed(c):
            var commitCheck = c.readItem()
            match commitCheck:
              UMPMCPopComplete(cmp):
                discard cmp.extractPinned().unpin()
              UMPMCPopSlotUncommitted(_):
                check false
          UMPMCPopSegmentExhausted(_):
            check false
          UMPMCPopSlotUncommitted(_):
            check false
          UMPMCPopReady(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false

    freeTestSegment(seg)

  test "checkCommitted returns Complete when slot is committed":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(-1, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSlotClaimed(c):
        var complete = c.readItem()

        match complete:
          UMPMCPopComplete(cmp):
            check cmp.value == 42
            check seg.prevConsumerIdx.load(moRelaxed) == 0
            check queue.itemCount.load(moRelaxed) == 2

            discard cmp.extractPinned().unpin()
          UMPMCPopSlotUncommitted(_):
            check false
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg)

  test "checkCommitted returns SlotUncommitted when not ready":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(-1, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(false, moRelaxed) # NOT committed yet

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    # tryClaimSlot checks committed flag BEFORE CAS
    var claimResult = loaded.tryClaimSlot()

    match claimResult:
      UMPMCPopSlotUncommitted(u):
        # Verify queue state unchanged (no pop happened)
        check queue.itemCount.load(moRelaxed) == 3
        check seg.prevConsumerIdx.load(moRelaxed) == -1

        discard u.extractPinned().unpin()
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg)

  test "advanceSegment returns Ready when next segment exists":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    seg1.prevConsumerIdx.store(63, moRelaxed)
    seg1.tail.store(64, moRelaxed)
    seg1.next.store(seg2, moRelease)
    seg2.prevConsumerIdx.store(-1, moRelaxed)
    seg2.tail.store(3, moRelaxed)
    seg2.data[0] = 100
    seg2.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg1, moRelaxed)
    queue.tailSegment.store(seg2, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSegmentExhausted(f):
        # Advance to next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPMCPopReady(r):
            # Now load and read from the new segment
            let loaded2 = r.loadSegment()
            check loaded2.segment == seg1 # MPMC doesn't update headSegment

            # The consumer would need to coordinate with other consumers
            # to determine when it's safe to advance headSegment
            # This test just verifies the typestate transition works correctly
          UMPMCPopEmpty(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg1)
    freeTestSegment(seg2)

  test "advanceSegment returns Empty when no next segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(5, moRelaxed)
    seg.tail.store(5, moRelaxed) # prevConsumerIdx + 1 >= tail

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSegmentExhausted(f):
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPMCPopEmpty(e):
            discard e.extractPinned().unpin()
          UMPMCPopReady(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopSlotUncommitted(_):
        check false
      UMPMCPopReady(_):
        check false

    freeTestSegment(seg)
