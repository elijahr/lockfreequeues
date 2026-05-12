## Tests for unbounded MPSC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## We use the high-level DEBRA API (registerThread) for setup.

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_mpsc_push
import lockfreequeues/typestates/unbounded_mpsc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedMupsicBase[64, int, 4]
  TestSegment = UMPSCSegment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.head = 0
  for i in 0 ..< 64:
    result.committed[i].store(false, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "MPSC Pop Typestate":
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
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.head >= 0
    check loaded.tail >= loaded.head
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    # Clean up
    var checkResult = loaded.checkSlot()
    match checkResult:
      UMPSCPopSlotAvailable(s):
        var commitResult = s.checkCommitted()
        match commitResult:
          UMPSCPopComplete(c):
            discard c.extractPinned().unpin()
          UMPSCPopSlotUncommitted(_):
            check false
      UMPSCPopSegmentExhausted(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads head segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head = 5
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.head == 5
    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation and VERIFY value read
    var checkResult = loaded.checkSlot()

    # Pre-populate data for verification
    seg.data[5] = 77
    seg.committed[5].store(true, moRelaxed)

    match checkResult:
      UMPSCPopSlotAvailable(s):
        var complete = s.checkCommitted()
        match complete:
          UMPSCPopComplete(c):
            check c.value == 77
            check seg.head == 6 # Verify head advanced
            discard c.extractPinned().unpin()
          UMPSCPopSlotUncommitted(_):
            check false
      UMPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "checkSlot returns SlotAvailable when items exist":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head = 0
    seg.tail.store(5, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var checkResult =
      startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment().checkSlot()

    match checkResult:
      UMPSCPopSlotAvailable(s):
        check s.slot == 0

        # Read item and VERIFY value
        var complete = s.checkCommitted()
        match complete:
          UMPSCPopComplete(c):
            check c.value == 42
            check seg.head == 1 # Verify head advanced
            discard c.extractPinned().unpin()
          UMPSCPopSlotUncommitted(_):
            check false
      UMPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "checkSlot returns SegmentExhausted when empty":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head = 5
    seg.tail.store(5, moRelaxed) # head == tail, no items

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var checkResult =
      startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment().checkSlot()

    match checkResult:
      UMPSCPopSegmentExhausted(f):
        # Try to advance - should return Empty since no next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPSCPopEmpty(e):
            # Verify queue state remains consistent
            check queue.itemCount.load(moRelaxed) == 0
            check queue.headSegment.load(moRelaxed) == seg

            discard e.extractPinned().unpin()
          UMPSCPopReady(_):
            check false
      UMPSCPopSlotAvailable(_):
        check false

    freeTestSegment(seg)

  test "checkCommitted returns Complete when slot is committed":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head = 0
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var slotAvail =
      startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment().checkSlot()

    match slotAvail:
      UMPSCPopSlotAvailable(s):
        var complete = s.checkCommitted()

        match complete:
          UMPSCPopComplete(c):
            check c.value == 42
            check seg.head == 1
            check queue.itemCount.load(moRelaxed) == 2

            discard c.extractPinned().unpin()
          UMPSCPopSlotUncommitted(_):
            check false
      UMPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "checkCommitted returns SlotUncommitted when not ready":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.head = 0
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.committed[0].store(false, moRelaxed) # NOT committed yet

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var slotAvail =
      startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment().checkSlot()

    match slotAvail:
      UMPSCPopSlotAvailable(s):
        var uncommitted = s.checkCommitted()

        match uncommitted:
          UMPSCPopSlotUncommitted(u):
            # Verify queue state unchanged (no pop happened)
            check queue.itemCount.load(moRelaxed) == 3
            check seg.head == 0

            discard u.extractPinned().unpin()
          UMPSCPopComplete(_):
            check false
      UMPSCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "advanceSegment returns Ready when next segment exists":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    seg1.head = 64
    seg1.tail.store(64, moRelaxed)
    seg1.next.store(seg2, moRelease)
    seg2.head = 0
    seg2.tail.store(3, moRelaxed)
    seg2.data[0] = 100
    seg2.committed[0].store(true, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg1, moRelaxed)
    queue.tailSegment.store(seg2, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    var checkResult =
      startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment().checkSlot()

    match checkResult:
      UMPSCPopSegmentExhausted(f):
        # Advance to next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPSCPopReady(r):
            check queue.headSegment.load(moRelaxed) == seg2 # Head advanced

            # Now load and read from the new segment
            let loaded2 = r.loadSegment()
            check loaded2.segment == seg2

            var checkResult2 = loaded2.checkSlot()
            match checkResult2:
              UMPSCPopSlotAvailable(s):
                # Read item and VERIFY we're reading from seg2, not seg1
                var complete = s.checkCommitted()
                match complete:
                  UMPSCPopComplete(c):
                    check c.value == 100
                    check seg2.head == 1
                    discard c.extractPinned().unpin()
                  UMPSCPopSlotUncommitted(_):
                    check false
              UMPSCPopSegmentExhausted(_):
                check false
          UMPSCPopEmpty(_):
            check false
      UMPSCPopSlotAvailable(_):
        check false

    freeTestSegment(seg1)
    freeTestSegment(seg2)
