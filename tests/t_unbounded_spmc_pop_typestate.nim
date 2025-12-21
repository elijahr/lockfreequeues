## Tests for unbounded SPMC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## Multiple consumers use CAS on prevConsumerIdx to coordinate.

import unittest2
import atomics
import debra

import lockfreequeues/typestates/unbounded_spmc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedSipmucBase[64, int, 4]
  TestSegment = SPMCSegment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)

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
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail >= loaded.prevConsumerIdx
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    let claimResult = loaded.tryClaimSlot()
    discard claimResult.spmcpopslotclaimed.readItem().extractPinned().unpin()
    freeTestSegment(seg)

  test "loadSegment loads head segment and prevConsumerIdx":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(4, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.prevConsumerIdx == 4
    check loaded.tail == 10
    check loaded.segment == seg

    check loaded.segment.next.load(moRelaxed) == nil

    seg.data[5] = 77
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == sSPMCPopSlotClaimed

    let complete = claimResult.spmcpopslotclaimed.readItem()
    check complete.value == 77
    discard complete.extractPinned().unpin()

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(-1, moRelaxed)
    seg.tail.store(5, moRelaxed)
    seg.data[0] = 42

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == sSPMCPopSlotClaimed
    check claimResult.spmcpopslotclaimed.slot == 0

    let complete = claimResult.spmcpopslotclaimed.readItem()
    check complete.value == 42
    check seg.prevConsumerIdx.load(moRelaxed) == 0
    discard complete.extractPinned().unpin()

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when no items":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(4, moRelaxed)
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == sSPMCPopSegmentExhausted

    let advanceResult = claimResult.spmcpopsegmentexhausted.advanceSegment()

    check advanceResult.kind == sSPMCPopEmpty

    discard advanceResult.spmcpopempty.extractPinned().unpin()

    freeTestSegment(seg)

  test "tryClaimSlot returns Ready when CAS fails (retry path)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(2, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.prevConsumerIdx == 2

    # Simulate another thread advancing prevConsumerIdx
    discard seg.prevConsumerIdx.fetchAdd(1, moRelaxed) # Now 3

    # tryClaimSlot should detect CAS failure and return Ready
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == sSPMCPopReady

    # Clean up - do a successful operation
    seg.data[4] = 99
    let claimResult2 = claimResult.spmcpopready.loadSegment().tryClaimSlot()
    check claimResult2.kind == sSPMCPopSlotClaimed
    discard claimResult2.spmcpopslotclaimed.readItem().extractPinned().unpin()

    freeTestSegment(seg)

  test "readItem reads value correctly":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(-1, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.data[1] = 43
    seg.data[2] = 44

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    let complete = claimResult.spmcpopslotclaimed.readItem()

    check complete.value == 42
    check seg.prevConsumerIdx.load(moRelaxed) == 0
    check queue.itemCount.load(moRelaxed) == 2

    discard complete.extractPinned().unpin()

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

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg1
    queue.tailSegment = seg2
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    let claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == sSPMCPopSegmentExhausted

    let advanceResult = claimResult.spmcpopsegmentexhausted.advanceSegment()

    check advanceResult.kind == sSPMCPopReady

    # Note: Unlike MPSC, SPMC doesn't update headSegment during advanceSegment
    # The consumer needs to coordinate segment advancement at a higher level
    # This test just verifies the typestate transition works correctly

    freeTestSegment(seg1)
    freeTestSegment(seg2)
