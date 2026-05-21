## Tests for unbounded MPMC push typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## MPMC push uses CAS coordination and committed flags like MPSC.

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_mpmc_push

# Type aliases for our test types
type
  TestQueue = UnboundedMupmucBase[64, int, 4, ccMulti]
  TestSegment = MPMCSegment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  # Initialize committed flags
  for i in 0 ..< 64:
    result.committed[i].store(false, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "MPMC Push Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded =
      startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.tail >= 0
    check loaded.segment != nil
    check loaded.segment.prevConsumerIdx.load(moRelaxed) == -1
    check loaded.segment.next.load(moRelaxed) == nil

    # Clean up
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == mMPMCPushSlotClaimed
    discard claimResult.mpmcpushslotclaimed
      .writeItem(0)
      .markCommitted()
      .extractPinned()
      .unpin()
    freeTestSegment(seg)

  test "loadSegment loads tail segment":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(10, moRelaxed) # Pre-set tail

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded =
      startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible and intact
    check loaded.segment.prevConsumerIdx.load(moRelaxed) == -1
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == mMPMCPushSlotClaimed

    # Write item and VERIFY the value was written
    let complete = claimResult.mpmcpushslotclaimed.writeItem(42).markCommitted()
    check seg.data[10] == 42 # Verify write to correct slot
    check seg.committed[10].load(moRelaxed) == true # Verify committed
    check seg.tail.load(moRelaxed) == 11 # Verify tail advanced
    discard complete.extractPinned().unpin()

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == mMPMCPushSlotClaimed
    check claimResult.mpmcpushslotclaimed.slot == 0

    # Write item and VERIFY
    discard claimResult.mpmcpushslotclaimed
      .writeItem(42)
      .markCommitted()
      .extractPinned()
      .unpin()

    check seg.data[0] == 42
    check seg.committed[0].load(moRelaxed) == true
    check seg.tail.load(moRelaxed) == 1

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentFull when segment full":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed) # Full segment

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == mMPMCPushSegmentFull

    # Allocate new segment and retry
    var newSeg = newTestSegment()
    let claimResult2 = claimResult.mpmcpushsegmentfull
      .allocateNewSegment(newSeg)
      .loadSegment()
      .tryClaimSlot()

    check claimResult2.kind == mMPMCPushSlotClaimed

    discard claimResult2.mpmcpushslotclaimed
      .writeItem(42)
      .markCommitted()
      .extractPinned()
      .unpin()

    # Verify write went to NEW segment, not old one
    check newSeg.data[0] == 42
    check newSeg.committed[0].load(moRelaxed) == true
    check newSeg.tail.load(moRelaxed) == 1
    check seg.next.load(moRelaxed) == newSeg # Segments correctly linked
    check seg.tail.load(moRelaxed) == 64 # Old segment unchanged

    freeTestSegment(seg)
    freeTestSegment(newSeg)

  test "tryClaimSlot returns Ready when CAS fails (retry path)":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Load segment with tail=5
    let loaded =
      startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail == 5

    # Simulate another thread advancing tail (race condition)
    discard seg.tail.fetchAdd(1, moRelaxed) # Now tail is 6

    # tryClaimSlot should detect CAS failure and return Ready for retry
    let claimResult = loaded.tryClaimSlot()
    check claimResult.kind == mMPMCPushReady

    # Clean up - do a successful operation
    let claimResult2 = claimResult.mpmcpushready.loadSegment().tryClaimSlot()
    check claimResult2.kind == mMPMCPushSlotClaimed
    discard claimResult2.mpmcpushslotclaimed
      .writeItem(99)
      .markCommitted()
      .extractPinned()
      .unpin()

    freeTestSegment(seg)

  test "allocateNewSegment handles allocation race":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Simulate another thread already linked a segment
    var seg2 = newTestSegment()
    seg.next.store(seg2, moRelease)

    # Now try to allocate our own segment
    var seg3 = newTestSegment()
    let claimResult = startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == mMPMCPushSegmentFull

    # Use tryAllocateNewSegment to detect the race
    let (ready, allocated) = claimResult.mpmcpushsegmentfull.tryAllocateNewSegment(seg3)

    check allocated == false # Lost the race, another thread allocated

    # Should still work - retry and use the winner's segment
    let claimResult2 = ready.loadSegment().tryClaimSlot()
    check claimResult2.kind == mMPMCPushSlotClaimed

    discard claimResult2.mpmcpushslotclaimed
      .writeItem(42)
      .markCommitted()
      .extractPinned()
      .unpin()

    # Should have written to seg2 (winner's segment), not seg3
    check seg2.data[0] == 42

    # Clean up - seg3 should be freed by caller since allocation failed
    freeTestSegment(seg)
    freeTestSegment(seg2)
    freeTestSegment(seg3)

  test "writeItem writes data correctly":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    check claimResult.kind == mMPMCPushSlotClaimed

    let written = claimResult.mpmcpushslotclaimed.writeItem(42)

    # Verify data written but not yet committed
    check seg.data[0] == 42
    check seg.committed[0].load(moRelaxed) == false

    # Now commit it
    discard written.markCommitted().extractPinned().unpin()

    check seg.committed[0].load(moRelaxed) == true
    check queue.itemCount.load(moRelaxed) == 1

    freeTestSegment(seg)

  test "markCommitted sets committed flag and updates itemCount":
    var manager = initDebraManager[4, ccMulti]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let claimResult = startPush[int, 64, 4, ccMulti](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    let complete = claimResult.mpmcpushslotclaimed.writeItem(42).markCommitted()

    check seg.data[0] == 42
    check seg.committed[0].load(moRelaxed) == true
    check seg.tail.load(moRelaxed) == 1
    check queue.itemCount.load(moRelaxed) == 1

    discard complete.extractPinned().unpin()

    freeTestSegment(seg)
