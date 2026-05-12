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
  TestQueue = UnboundedMupmucBase[64, int, 4]
  TestSegment = UMPMCSegment[64, int]

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
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.tail >= 0
    check loaded.segment != nil
    check loaded.segment.prevConsumerIdx.load(moRelaxed) == -1
    check loaded.segment.next.load(moRelaxed) == nil

    # Clean up
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPushSlotClaimed(c):
        discard c
          .writeItem(0)
          .markCommitted()
          .extractPinned()
          .unpin()
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads tail segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(10, moRelaxed) # Pre-set tail

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible and intact
    check loaded.segment.prevConsumerIdx.load(moRelaxed) == -1
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPushSlotClaimed(c):
        # Write item and VERIFY the value was written
        let complete = c.writeItem(42).markCommitted()
        check seg.data[10] == 42 # Verify write to correct slot
        check seg.committed[10].load(moRelaxed) == true # Verify committed
        check seg.tail.load(moRelaxed) == 11 # Verify tail advanced
        discard complete.extractPinned().unpin()
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSlotClaimed(c):
        check c.slot == 0

        # Write item and VERIFY
        discard c
          .writeItem(42)
          .markCommitted()
          .extractPinned()
          .unpin()

        check seg.data[0] == 42
        check seg.committed[0].load(moRelaxed) == true
        check seg.tail.load(moRelaxed) == 1
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentFull when segment full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed) # Full segment

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    # Allocate new segment and retry. A1: the standalone `allocateNewSegment`
    # transition variant was removed (verb-count consolidation); the tuple-
    # returning `tryAllocateNewSegment` is the single canonical form. We
    # discard the `allocated` bit here because this test stages an
    # uncontested allocation (no peer thread); it always wins.
    var newSeg = newTestSegment()
    match claimResult:
      UMPMCPushSegmentFull(f):
        let (ready2, _) = f.tryAllocateNewSegment(newSeg)
        var claimResult2 = ready2.loadSegment().tryClaimSlot()

        match claimResult2:
          UMPMCPushSlotClaimed(c):
            discard c
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
          UMPMCPushSegmentFull(_):
            check false
          UMPMCPushReady(_):
            check false
      UMPMCPushSlotClaimed(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)
    freeTestSegment(newSeg)

  test "tryClaimSlot returns Ready when CAS fails (retry path)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Load segment with tail=5
    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail == 5

    # Simulate another thread advancing tail (race condition)
    discard seg.tail.fetchAdd(1, moRelaxed) # Now tail is 6

    # tryClaimSlot should detect CAS failure and return Ready for retry
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPushReady(r):
        # Clean up - do a successful operation
        var claimResult2 = r.loadSegment().tryClaimSlot()
        match claimResult2:
          UMPMCPushSlotClaimed(c):
            discard c
              .writeItem(99)
              .markCommitted()
              .extractPinned()
              .unpin()
          UMPMCPushSegmentFull(_):
            check false
          UMPMCPushReady(_):
            check false
      UMPMCPushSlotClaimed(_):
        check false
      UMPMCPushSegmentFull(_):
        check false

    freeTestSegment(seg)

  test "allocateNewSegment handles allocation race":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Simulate another thread already linked a segment
    var seg2 = newTestSegment()
    seg.next.store(seg2, moRelease)

    # Now try to allocate our own segment
    var seg3 = newTestSegment()
    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSegmentFull(f):
        # Use tryAllocateNewSegment to detect the race
        let (ready, allocated) = f.tryAllocateNewSegment(seg3)

        check allocated == false # Lost the race, another thread allocated

        # Should still work - retry and use the winner's segment
        var claimResult2 = ready.loadSegment().tryClaimSlot()
        match claimResult2:
          UMPMCPushSlotClaimed(c):
            discard c
              .writeItem(42)
              .markCommitted()
              .extractPinned()
              .unpin()

            # Should have written to seg2 (winner's segment), not seg3
            check seg2.data[0] == 42
          UMPMCPushSegmentFull(_):
            check false
          UMPMCPushReady(_):
            check false
      UMPMCPushSlotClaimed(_):
        check false
      UMPMCPushReady(_):
        check false

    # Clean up - seg3 should be freed by caller since allocation failed
    freeTestSegment(seg)
    freeTestSegment(seg2)
    freeTestSegment(seg3)

  test "writeItem writes data correctly":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSlotClaimed(c):
        let written = c.writeItem(42)

        # Verify data written but not yet committed
        check seg.data[0] == 42
        check seg.committed[0].load(moRelaxed) == false

        # Now commit it
        discard written.markCommitted().extractPinned().unpin()

        check seg.committed[0].load(moRelaxed) == true
        check queue.itemCount.load(moRelaxed) == 1
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)

  test "markCommitted sets committed flag and updates itemCount":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSlotClaimed(c):
        let complete = c.writeItem(42).markCommitted()

        check seg.data[0] == 42
        check seg.committed[0].load(moRelaxed) == true
        check seg.tail.load(moRelaxed) == 1
        check queue.itemCount.load(moRelaxed) == 1

        discard complete.extractPinned().unpin()
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)
