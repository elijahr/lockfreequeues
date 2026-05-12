## Tests for unbounded SPSC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## SPSC doesn't need DEBRA - single producer/consumer, no hazardous reclamation.

import unittest2
import lockfreequeues/atomic_dsl

import lockfreequeues/typestates/unbounded_spsc_push
import lockfreequeues/typestates/unbounded_spsc_pop

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

suite "SPSC Pop Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed) # One item available
    seg.data[0] = 99

    var queue: TestQueue
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPop[int, 64](addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.head >= 0
    check loaded.tail >= loaded.head
    check loaded.segment != nil
    check loaded.segment.data[0] == 99 # Verify data array accessible

    # Clean up
    var checkResult = loaded.checkSlot()
    match checkResult:
      USPSCPopSlotAvailable(s):
        discard s.readItem()
      USPSCPopSegmentExhausted(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads head segment":
    var seg = newTestSegment()
    seg.head.store(5, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64](addr queue).loadSegment()

    check loaded.head == 5
    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation and VERIFY value read
    var checkResult = loaded.checkSlot()

    # Pre-populate data for verification
    seg.data[5] = 77

    match checkResult:
      USPSCPopSlotAvailable(s):
        let complete = s.readItem()
        check complete.value == 77 # Verify we read correct value
        check seg.head.load(moRelaxed) == 6 # Verify head advanced
      USPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "checkSlot returns SlotAvailable when items exist":
    var seg = newTestSegment()
    seg.head.store(0, moRelaxed)
    seg.tail.store(5, moRelaxed) # 5 items available
    seg.data[0] = 42

    var queue: TestQueue
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var checkResult = startPop[int, 64](addr queue).loadSegment().checkSlot()

    match checkResult:
      USPSCPopSlotAvailable(s):
        check s.slot == 0

        # Read item and VERIFY value
        let complete = s.readItem()
        check complete.value == 42 # Verify we got correct value
        check seg.head.load(moRelaxed) == 1 # Verify head advanced
      USPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "checkSlot returns SegmentExhausted when empty":
    var seg = newTestSegment()
    seg.head.store(5, moRelaxed)
    seg.tail.store(5, moRelaxed) # head == tail, no items

    var queue: TestQueue
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var checkResult = startPop[int, 64](addr queue).loadSegment().checkSlot()

    match checkResult:
      USPSCPopSegmentExhausted(f):
        # Try to advance - should return Empty since no next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          USPSCPopEmpty(_):
            # Verify queue state remains consistent
            check queue.itemCount.load(moRelaxed) == 0 # Queue still reports empty
            check queue.headSegment.load(moRelaxed) == seg
              # No advancement happened (expected - no next segment)
          USPSCPopReady(_):
            check false
      USPSCPopSlotAvailable(_):
        check false

    freeTestSegment(seg)

  test "advanceSegment returns Ready when next segment exists":
    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    seg1.head.store(64, moRelaxed)
    seg1.tail.store(64, moRelaxed) # Full and exhausted
    seg1.next.store(seg2, moRelease)
    seg2.head.store(0, moRelaxed)
    seg2.tail.store(3, moRelaxed) # 3 items in next segment
    seg2.data[0] = 100

    var queue: TestQueue
    queue.headSegment.store(seg1, moRelaxed)
    queue.tailSegment.store(seg2, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    var checkResult = startPop[int, 64](addr queue).loadSegment().checkSlot()

    match checkResult:
      USPSCPopSegmentExhausted(f):
        # Advance to next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          USPSCPopReady(r):
            check queue.headSegment.load(moRelaxed) == seg2 # Head advanced

            # Now load and read from the new segment
            let loaded2 = r.loadSegment()
            check loaded2.segment == seg2

            var checkResult2 = loaded2.checkSlot()
            match checkResult2:
              USPSCPopSlotAvailable(s):
                # Read item and VERIFY we're reading from seg2, not seg1
                let complete = s.readItem()
                check complete.value == 100 # Verify value from seg2
                check seg2.head.load(moRelaxed) == 1 # Verify seg2's head advanced
              USPSCPopSegmentExhausted(_):
                check false
          USPSCPopEmpty(_):
            check false
      USPSCPopSlotAvailable(_):
        check false

    freeTestSegment(seg1)
    freeTestSegment(seg2)

  test "readItem reads value and advances head":
    var seg = newTestSegment()
    seg.head.store(0, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.data[1] = 43
    seg.data[2] = 44

    var queue: TestQueue
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var checkResult = startPop[int, 64](addr queue).loadSegment().checkSlot()

    match checkResult:
      USPSCPopSlotAvailable(s):
        let complete = s.readItem()

        check complete.value == 42
        check seg.head.load(moRelaxed) == 1
        check queue.itemCount.load(moRelaxed) == 2
      USPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)
