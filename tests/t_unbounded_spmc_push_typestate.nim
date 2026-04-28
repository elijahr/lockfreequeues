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
  TestQueue = UnboundedSipmuc[64, int, 4]
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
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.strategy = 0 # Manual
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
    let checkResult = loaded.checkFull()
    discard checkResult.spmcpushslotready.writeItem(0).extractPinned().unpin()
    freeTestSegment(seg)

  test "loadSegment loads tail segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(10, moRelaxed) # Pre-set tail

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.strategy = 0 # Manual
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
    let checkResult = loaded.checkFull()
    check checkResult.kind == sSPMCPushSlotReady

    # Write item and VERIFY the value was written
    let complete = checkResult.spmcpushslotready.writeItem(42)
    check seg.data[10] == 42 # Consume: verify write to correct slot
    check seg.tail.load(moRelaxed) == 11 # Verify tail advanced
    discard complete.extractPinned().unpin()

    freeTestSegment(seg)

  test "checkFull returns SlotReady when not full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.strategy = 0 # Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    let checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkFull()

    check checkResult.kind == sSPMCPushSlotReady
    check checkResult.spmcpushslotready.slot == 0

    # Write item and VERIFY the value was written
    discard checkResult.spmcpushslotready.writeItem(42).extractPinned().unpin()

    check seg.data[0] == 42 # Consume: verify write happened
    check seg.tail.load(moRelaxed) == 1 # Verify tail advanced

    freeTestSegment(seg)

  test "checkFull returns SegmentFull when full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed) # Full segment

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.strategy = 0 # Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    let checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkFull()

    check checkResult.kind == sSPMCPushSegmentFull

    # Allocate new segment and retry
    var newSeg = newTestSegment()
    let checkResult2 = checkResult.spmcpushsegmentfull
      .allocateNewSegment(newSeg)
      .loadSegment()
      .checkFull()

    check checkResult2.kind == sSPMCPushSlotReady

    discard checkResult2.spmcpushslotready.writeItem(42).extractPinned().unpin()

    # Consume: verify write went to NEW segment, not old one
    check newSeg.data[0] == 42 # Value written to new segment
    check newSeg.tail.load(moRelaxed) == 1 # New segment tail advanced
    check seg.next.load(moRelaxed) == newSeg # Segments correctly linked
    check seg.tail.load(moRelaxed) == 64 # Old segment unchanged

    freeTestSegment(seg)
    freeTestSegment(newSeg)

  test "writeItem writes data and publishes":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.strategy = 0 # Manual
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)
    queue.consumerCount.store(0, moRelaxed)

    let checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkFull()

    discard checkResult.spmcpushslotready.writeItem(42).extractPinned().unpin()

    check seg.data[0] == 42
    check seg.tail.load(moRelaxed) == 1
    check queue.itemCount.load(moRelaxed) == 1

    freeTestSegment(seg)
