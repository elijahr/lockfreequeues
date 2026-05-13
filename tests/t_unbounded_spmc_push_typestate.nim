## Tests for unbounded SPMC push typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## We use the high-level DEBRA API (registerThread) for setup.

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_spmc_push

# Type aliases for our test types
type
  TestQueue = UnboundedSipmucBase[64, int, 4]
  TestSegment = Segment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "SPMC Push Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.strategy = Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    # Actually use the types with real data
    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.tail >= 0
    check loaded.segment != nil
    check loaded.segment.prevConsumerIdx.load(moRelaxed) == -1
    check loaded.segment.next.load(moRelaxed) == nil

    # Clean up
    var checkResult = loaded.checkFull()
    match checkResult:
      USPMCPushSlotReady(s):
        discard s.writeItem(0).extractPinned().unpin()
      USPMCPushSegmentFull(_):
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
    queue.tailSegment = seg
    queue.strategy = Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    # Use unpinned/pin from debra - chain to avoid copy issues
    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible and intact
    check loaded.segment.prevConsumerIdx.load(moRelaxed) == -1
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation
    var checkResult = loaded.checkFull()
    match checkResult:
      USPMCPushSlotReady(s):
        # Write item and VERIFY the value was written
        let complete = s.writeItem(42)
        check seg.data[10] == 42 # Consume: verify write to correct slot
        check seg.tail.load(moRelaxed) == 11 # Verify tail advanced
        discard complete.extractPinned().unpin()
      USPMCPushSegmentFull(_):
        check false

    freeTestSegment(seg)

  test "checkFull returns SlotReady when not full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.strategy = Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    var checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkFull()

    match checkResult:
      USPMCPushSlotReady(s):
        check s.slot == 0

        # Write item and VERIFY the value was written
        discard s.writeItem(42).extractPinned().unpin()

        check seg.data[0] == 42 # Consume: verify write happened
        check seg.tail.load(moRelaxed) == 1 # Verify tail advanced
      USPMCPushSegmentFull(_):
        check false

    freeTestSegment(seg)

  test "checkFull returns SegmentFull when full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed) # Full segment

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.strategy = Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    var checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkFull()

    # Allocate new segment and retry
    var newSeg = newTestSegment()
    match checkResult:
      USPMCPushSegmentFull(f):
        var checkResult2 = f
          .allocateNewSegment(newSeg)
          .loadSegment()
          .checkFull()

        match checkResult2:
          USPMCPushSlotReady(s):
            discard s.writeItem(42).extractPinned().unpin()

            # Consume: verify write went to NEW segment, not old one
            check newSeg.data[0] == 42 # Value written to new segment
            check newSeg.tail.load(moRelaxed) == 1 # New segment tail advanced
            check seg.next.load(moRelaxed) == newSeg # Segments correctly linked
            check seg.tail.load(moRelaxed) == 64 # Old segment unchanged
          USPMCPushSegmentFull(_):
            check false
      USPMCPushSlotReady(_):
        check false

    freeTestSegment(seg)
    freeTestSegment(newSeg)

  test "writeItem writes data and publishes":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.strategy = Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    var checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkFull()

    match checkResult:
      USPMCPushSlotReady(s):
        discard s.writeItem(42).extractPinned().unpin()

        check seg.data[0] == 42
        check seg.tail.load(moRelaxed) == 1
        check queue.itemCount.load(moRelaxed) == 1
      USPMCPushSegmentFull(_):
        check false

    freeTestSegment(seg)

suite "Task 11 LCRQ cell-state constants":
  test "CellEmpty/CellFilled/CellClosed are distinct uint8 literals":
    check CellEmpty == 0'u8
    check CellFilled == 1'u8
    check CellClosed == 2'u8
    check CellEmpty != CellFilled
    check CellFilled != CellClosed
