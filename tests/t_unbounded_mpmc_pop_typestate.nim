## Tests for unbounded MPMC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## MPMC pop combines CAS coordination (like SPMC) with committed flag checking (like MPSC).

import unittest2
import atomics
import debra

import lockfreequeues/typestates/unbounded_mpmc_push
import lockfreequeues/typestates/unbounded_mpmc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedMupmucBase[64, int, 4]
  TestSegment = MPMCSegment[64, int]

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
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.prevConsumerIdx == -1
    check loaded.tail >= loaded.prevConsumerIdx
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    # Clean up
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == mMPMCPopSlotClaimed
    let readResult = claimResult.mpmcpopslotclaimed.readItem()
    discard readResult.mpmcpopcomplete
      .extractPinned()
      .unpin()
    freeTestSegment(seg)


  test "loadSegment loads head segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(4, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment()

    check loaded.prevConsumerIdx == 4
    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation and VERIFY value read
    seg.data[5] = 77
    seg.committed[5].store(true, moRelaxed)

    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == mMPMCPopSlotClaimed

    let complete = claimResult.mpmcpopslotclaimed.readItem()
    check complete.kind == mMPMCPopComplete
    check complete.mpmcpopcomplete.value == 77
    discard complete.mpmcpopcomplete.extractPinned().unpin()

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
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().tryClaimSlot()

    check claimResult.kind == mMPMCPopSlotClaimed
    check claimResult.mpmcpopslotclaimed.slot == 0

    # Read item and VERIFY value
    let complete = claimResult.mpmcpopslotclaimed.readItem()
    check complete.kind == mMPMCPopComplete
    check complete.mpmcpopcomplete.value == 42
    check seg.prevConsumerIdx.load(moRelaxed) == 0
    discard complete.mpmcpopcomplete.extractPinned().unpin()

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
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().tryClaimSlot()

    check claimResult.kind == mMPMCPopSegmentExhausted

    # Try to advance - should return Empty since no next segment
    let advanceResult = claimResult.mpmcpopsegmentexhausted
      .advanceSegment()

    check advanceResult.kind == mMPMCPopEmpty

    # Verify queue state remains consistent
    check queue.itemCount.load(moRelaxed) == 0

    discard advanceResult.mpmcpopempty.extractPinned().unpin()

    freeTestSegment(seg)


  test "tryClaimSlot returns Ready when CAS fails (simulate race)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(2, moRelaxed)
    seg.tail.store(10, moRelaxed)
    seg.data[3] = 99
    seg.data[4] = 88
    seg.committed[3].store(true, moRelaxed)  # Slot 3 is committed
    seg.committed[4].store(true, moRelaxed)  # Slot 4 is committed

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment()

    check loaded.prevConsumerIdx == 2

    # Simulate another thread advancing prevConsumerIdx
    discard seg.prevConsumerIdx.fetchAdd(1, moRelaxed)  # Now 3

    # tryClaimSlot should detect CAS failure and return Ready
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == mMPMCPopReady

    # Clean up - do a successful operation
    let claimResult2 = claimResult.mpmcpopready
      .loadSegment()
      .tryClaimSlot()
    check claimResult2.kind == mMPMCPopSlotClaimed
    let complete2 = claimResult2.mpmcpopslotclaimed.readItem()
    discard complete2.mpmcpopcomplete.extractPinned().unpin()

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
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().tryClaimSlot()

    check claimResult.kind == mMPMCPopSlotClaimed

    let complete = claimResult.mpmcpopslotclaimed.readItem()

    check complete.kind == mMPMCPopComplete
    check complete.mpmcpopcomplete.value == 42
    check seg.prevConsumerIdx.load(moRelaxed) == 0
    check queue.itemCount.load(moRelaxed) == 2

    discard complete.mpmcpopcomplete.extractPinned().unpin()

    freeTestSegment(seg)


  test "checkCommitted returns SlotUncommitted when not ready":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(-1, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(false, moRelaxed)  # NOT committed yet

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment()

    # tryClaimSlot checks committed flag BEFORE CAS
    let claimResult = loaded.tryClaimSlot()

    check claimResult.kind == mMPMCPopSlotUncommitted

    # Verify queue state unchanged (no pop happened)
    check queue.itemCount.load(moRelaxed) == 3
    check seg.prevConsumerIdx.load(moRelaxed) == -1

    discard claimResult.mpmcpopslotuncommitted.extractPinned().unpin()

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
    queue.headSegment = seg1
    queue.tailSegment.store(seg2, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    let claimResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().tryClaimSlot()

    check claimResult.kind == mMPMCPopSegmentExhausted

    # Advance to next segment
    let advanceResult = claimResult.mpmcpopsegmentexhausted
      .advanceSegment()

    check advanceResult.kind == mMPMCPopReady

    # Now load and read from the new segment
    let loaded2 = advanceResult.mpmcpopready.loadSegment()
    check loaded2.segment == seg1  # MPMC doesn't update headSegment

    # The consumer would need to coordinate with other consumers
    # to determine when it's safe to advance headSegment
    # This test just verifies the typestate transition works correctly

    freeTestSegment(seg1)
    freeTestSegment(seg2)


  test "advanceSegment returns Empty when no next segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.prevConsumerIdx.store(5, moRelaxed)
    seg.tail.store(5, moRelaxed)  # prevConsumerIdx + 1 >= tail

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().tryClaimSlot()

    check claimResult.kind == mMPMCPopSegmentExhausted

    let advanceResult = claimResult.mpmcpopsegmentexhausted
      .advanceSegment()

    check advanceResult.kind == mMPMCPopEmpty

    discard advanceResult.mpmcpopempty.extractPinned().unpin()

    freeTestSegment(seg)
