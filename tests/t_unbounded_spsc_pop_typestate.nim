## Tests for unbounded SPSC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## We use the high-level DEBRA API (registerThread) for setup.

import unittest2
import atomics
import debra

import lockfreequeues/typestates/unbounded_spsc_push
import lockfreequeues/typestates/unbounded_spsc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedSipsicBase[64, int, 4]
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

  test "typestate types exist and compile":
    # Verify state types exist (using U prefix for Unbounded) - now include T
    var ready: USPSCPopReady[int, 64, 4]
    var loaded: USPSCPopSegmentLoaded[int, 64, 4]
    var slotAvail: USPSCPopSlotAvailable[int, 64, 4]
    var exhausted: USPSCPopSegmentExhausted[int, 64, 4]
    var empty: USPSCPopEmpty[int, 64, 4]
    var complete: USPSCPopComplete[int, 64, 4]
    check true  # Types compile


  test "loadSegment loads head segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head.store(5, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment()

    check loaded.head == 5
    check loaded.tail == 10
    check loaded.segment == seg  # Now typed, not pointer comparison

    # Complete operation - extract pinned for unpin
    let checkResult = loaded.checkSlot()
    check checkResult.kind == uUSPSCPopSlotAvailable

    let complete = checkResult.uspscpopslotavailable.readItem()
    discard complete.extractPinned().unpin()

    freeTestSegment(seg)


  test "checkSlot returns SlotAvailable when items exist":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head.store(0, moRelaxed)
    seg.tail.store(5, moRelaxed)  # 5 items available
    seg.data[0] = 42

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().checkSlot()

    check checkResult.kind == uUSPSCPopSlotAvailable
    check checkResult.uspscpopslotavailable.slot == 0

    # Complete operation
    discard checkResult.uspscpopslotavailable.readItem()
      .extractPinned().unpin()

    freeTestSegment(seg)


  test "checkSlot returns SegmentExhausted when empty":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head.store(5, moRelaxed)
    seg.tail.store(5, moRelaxed)  # head == tail, no items

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().checkSlot()

    check checkResult.kind == uUSPSCPopSegmentExhausted

    # Try to advance - should return Empty since no next segment
    let advanceResult = checkResult.uspscpopsegmentexhausted
      .advanceSegment()

    check advanceResult.kind == uUSPSCPopEmpty

    discard advanceResult.uspscpopempty.extractPinned().unpin()

    freeTestSegment(seg)


  test "advanceSegment returns Ready when next segment exists":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    seg1.head.store(64, moRelaxed)
    seg1.tail.store(64, moRelaxed)  # Full and exhausted
    seg1.next.store(seg2, moRelease)
    seg2.head.store(0, moRelaxed)
    seg2.tail.store(3, moRelaxed)  # 3 items in next segment
    seg2.data[0] = 100

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg1
    queue.tailSegment = seg2
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    let checkResult = startPop[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegment().checkSlot()

    check checkResult.kind == uUSPSCPopSegmentExhausted

    # Advance to next segment
    let advanceResult = checkResult.uspscpopsegmentexhausted
      .advanceSegment()

    check advanceResult.kind == uUSPSCPopReady
    check queue.headSegment == seg2  # Head advanced

    # Now load and read from the new segment
    let loaded2 = advanceResult.uspscpopready.loadSegment()
    check loaded2.segment == seg2  # Now typed, not pointer comparison

    let checkResult2 = loaded2.checkSlot()
    check checkResult2.kind == uUSPSCPopSlotAvailable

    discard checkResult2.uspscpopslotavailable.readItem()
      .extractPinned().unpin()

    freeTestSegment(seg1)
    freeTestSegment(seg2)


  test "readItem reads value and advances head":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head.store(0, moRelaxed)
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

    let checkResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .checkSlot()

    let complete = checkResult.uspscpopslotavailable.readItem()

    check complete.value == 42
    check seg.head.load(moRelaxed) == 1
    check queue.itemCount.load(moRelaxed) == 2

    discard complete.extractPinned().unpin()

    freeTestSegment(seg)
