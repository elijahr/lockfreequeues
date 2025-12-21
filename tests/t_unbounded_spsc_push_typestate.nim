## Tests for unbounded SPSC push typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## SPSC doesn't need DEBRA - single producer/consumer, no hazardous reclamation.

import unittest2
import atomics

import lockfreequeues/typestates/unbounded_spsc_push

# Type aliases for our test types
type
  TestQueue = UnboundedSipsicBase[64, int]
  TestSegment = Segment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.head.store(0, moRelaxed)
  result.tail.store(0, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "SPSC Push Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var seg = newTestSegment()
    var queue: TestQueue
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPush[int, 64](addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.tail >= 0
    check loaded.segment != nil
    check loaded.segment.head.load(moRelaxed) == 0
    check loaded.segment.next.load(moRelaxed) == nil

    # Clean up
    let checkResult = loaded.checkFull()
    discard checkResult.spscpushslotready.writeItem(0)
    freeTestSegment(seg)

  test "loadSegment loads tail segment":
    var seg = newTestSegment()
    seg.tail.store(10, moRelaxed) # Pre-set tail

    var queue: TestQueue
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPush[int, 64](addr queue).loadSegment()

    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible and intact
    check loaded.segment.head.load(moRelaxed) == 0
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation
    let checkResult = loaded.checkFull()
    check checkResult.kind == sSPSCPushSlotReady

    # Write item and VERIFY the value was written
    discard checkResult.spscpushslotready.writeItem(42)
    check seg.data[10] == 42 # Verify write to correct slot
    check seg.tail.load(moRelaxed) == 11 # Verify tail advanced

    freeTestSegment(seg)

  test "checkFull returns SlotReady when not full":
    var seg = newTestSegment()
    var queue: TestQueue
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPush[int, 64](addr queue).loadSegment().checkFull()

    check checkResult.kind == sSPSCPushSlotReady
    check checkResult.spscpushslotready.slot == 0

    # Write item and VERIFY the value was written
    discard checkResult.spscpushslotready.writeItem(42)

    check seg.data[0] == 42 # Verify write happened
    check seg.tail.load(moRelaxed) == 1 # Verify tail advanced

    freeTestSegment(seg)

  test "checkFull returns SegmentFull when full":
    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed) # Full segment

    var queue: TestQueue
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPush[int, 64](addr queue).loadSegment().checkFull()

    check checkResult.kind == sSPSCPushSegmentFull

    # Allocate new segment and retry
    var newSeg = newTestSegment()
    let checkResult2 = checkResult.spscpushsegmentfull
      .allocateNewSegment(newSeg)
      .loadSegment()
      .checkFull()

    check checkResult2.kind == sSPSCPushSlotReady

    discard checkResult2.spscpushslotready.writeItem(42)

    # Verify write went to NEW segment, not old one
    check newSeg.data[0] == 42 # Value written to new segment
    check newSeg.tail.load(moRelaxed) == 1 # New segment tail advanced
    check seg.next.load(moRelaxed) == newSeg # Segments correctly linked
    check seg.tail.load(moRelaxed) == 64 # Old segment unchanged

    freeTestSegment(seg)
    freeTestSegment(newSeg)

  test "writeItem writes data and publishes":
    var seg = newTestSegment()
    var queue: TestQueue
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPush[int, 64](addr queue).loadSegment().checkFull()

    discard checkResult.spscpushslotready.writeItem(42)

    check seg.data[0] == 42
    check seg.tail.load(moRelaxed) == 1
    check queue.itemCount.load(moRelaxed) == 1

    freeTestSegment(seg)
