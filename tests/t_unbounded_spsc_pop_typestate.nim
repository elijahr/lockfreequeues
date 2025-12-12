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
    # Verify state types exist
    var ready: SPSCPopReady[64, 4]
    var loaded: SPSCPopSegmentLoaded[64, 4]
    var slotAvail: SPSCPopSlotAvailable[64, 4]
    var exhausted: SPSCPopSegmentExhausted[64, 4]
    var empty: SPSCPopEmpty[64, 4]
    var complete: SPSCPopComplete[64, 4]
    check true  # Types compile


  test "loadSegmentTyped loads head segment":
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
    ).loadSegmentTyped[:int, 64, 4]()

    check loaded.head == 5
    check loaded.tail == 10
    check loaded.segment == cast[pointer](seg)

    # Complete operation - extract pinned for unpin
    let checkResult = loaded.checkSlot()
    check checkResult.kind == sSPSCPopSlotAvailable

    let complete = checkResult.spscpopslotavailable.readItemTyped[:int, 64, 4]()
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
    ).loadSegmentTyped[:int, 64, 4]().checkSlot()

    check checkResult.kind == sSPSCPopSlotAvailable
    check checkResult.spscpopslotavailable.slot == 0

    # Complete operation
    discard checkResult.spscpopslotavailable.readItemTyped[:int, 64, 4]()
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
    ).loadSegmentTyped[:int, 64, 4]().checkSlot()

    check checkResult.kind == sSPSCPopSegmentExhausted

    # Try to advance - should return Empty since no next segment
    let advanceResult = checkResult.spscpopsegmentexhausted
      .advanceSegmentTyped[:int, 64, 4]()

    check advanceResult.kind == sSPSCPopEmpty

    discard advanceResult.spscpopempty.extractPinned().unpin()

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
    ).loadSegmentTyped[:int, 64, 4]().checkSlot()

    check checkResult.kind == sSPSCPopSegmentExhausted

    # Advance to next segment
    let advanceResult = checkResult.spscpopsegmentexhausted
      .advanceSegmentTyped[:int, 64, 4]()

    check advanceResult.kind == sSPSCPopReady
    check queue.headSegment == seg2  # Head advanced

    # Now load and read from the new segment
    let loaded2 = advanceResult.spscpopready.loadSegmentTyped[:int, 64, 4]()
    check loaded2.segment == cast[pointer](seg2)

    let checkResult2 = loaded2.checkSlot()
    check checkResult2.kind == sSPSCPopSlotAvailable

    discard checkResult2.spscpopslotavailable.readItemTyped[:int, 64, 4]()
      .extractPinned().unpin()

    freeTestSegment(seg1)
    freeTestSegment(seg2)


  test "readItemTyped reads value and advances head":
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

    let complete = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegmentTyped[:int, 64, 4]()
      .checkSlot()
      .spscpopslotavailable
      .readItemTyped[:int, 64, 4]()

    check getValue[int, 64, 4](complete) == 42
    check seg.head.load(moRelaxed) == 1
    check queue.itemCount.load(moRelaxed) == 2

    discard complete.extractPinned().unpin()

    freeTestSegment(seg)
