## Tests for unbounded SPSC push typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## We use the high-level DEBRA API (registerThread) for setup.

import unittest2
import atomics
import debra

import lockfreequeues/typestates/unbounded_spsc_push

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


suite "SPSC Push Typestate":

  test "typestate types exist and compile":
    # Verify state types exist
    var ready: SPSCPushReady[64, 4]
    var loaded: SPSCPushSegmentLoaded[64, 4]
    var full: SPSCPushSegmentFull[64, 4]
    var slotReady: SPSCPushSlotReady[64, 4]
    var complete: SPSCPushComplete[64, 4]
    check true  # Types compile


  test "loadSegmentTyped loads tail segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(10, moRelaxed)  # Pre-set tail

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Use unpinned/pin from debra - chain to avoid copy issues
    let loaded = startPush[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegmentTyped[:int, 64, 4]()

    check loaded.tail == 10
    check loaded.segment == cast[pointer](seg)

    # Complete operation
    let checkResult = loaded.checkFull()
    check checkResult.kind == sSPSCPushSlotReady

    # Clean up - write item and extract pinned for unpin
    let complete = checkResult.spscpushslotready.writeItemTyped[:int, 64, 4](42)
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
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPush[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegmentTyped[:int, 64, 4]().checkFull()

    check checkResult.kind == sSPSCPushSlotReady
    check checkResult.spscpushslotready.slot == 0

    # Complete operation
    discard checkResult.spscpushslotready.writeItemTyped[:int, 64, 4](42)
      .extractPinned().unpin()

    freeTestSegment(seg)


  test "checkFull returns SegmentFull when full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed)  # Full segment

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let checkResult = startPush[int, 64, 4](
      unpinned(handle).pin(),
      addr queue
    ).loadSegmentTyped[:int, 64, 4]().checkFull()

    check checkResult.kind == sSPSCPushSegmentFull

    # Allocate new segment and retry
    var newSeg = newTestSegment()
    let checkResult2 = checkResult.spscpushsegmentfull
      .allocateNewSegmentTyped[:int, 64, 4](newSeg)
      .loadSegmentTyped[:int, 64, 4]()
      .checkFull()

    check checkResult2.kind == sSPSCPushSlotReady

    discard checkResult2.spscpushslotready
      .writeItemTyped[:int, 64, 4](42)
      .extractPinned().unpin()

    freeTestSegment(seg)
    freeTestSegment(newSeg)


  test "writeItemTyped writes data and publishes":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment = seg
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    discard startPush[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegmentTyped[:int, 64, 4]()
      .checkFull()
      .spscpushslotready
      .writeItemTyped[:int, 64, 4](42)
      .extractPinned()
      .unpin()

    check seg.data[0] == 42
    check seg.tail.load(moRelaxed) == 1
    check queue.itemCount.load(moRelaxed) == 1

    freeTestSegment(seg)
