## Tests for unbounded SPMC push typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## We use the high-level DEBRA API (registerThread) for setup.

import options
import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_spmc_push
import lockfreequeues/unbounded_sipmuc

# Type aliases for our test types
type
  TestQueue = UnboundedSipmucBase[64, int, 4]
  TestSegment = Segment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.consumerHead.store(0, moRelaxed)

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

    # Actually use the types with real data. Task 6: startPush carries
    # pendingItem into the typestate chain (3rd arg).
    let loaded =
      startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 0).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.tail >= 0
    check loaded.segment != nil
    check loaded.segment.consumerHead.load(moRelaxed) == 0
    check loaded.segment.next.load(moRelaxed) == nil

    # Clean up. Task 7 / C5: writeItem now takes only the typestate (no
    # slot/item args) and returns a variant USPMCPushCommitResult. Slot is
    # obtained internally via seg.tail.fetchAdd; item travels in pendingItem.
    var checkResult = loaded.checkFull()
    match checkResult:
      USPMCPushSlotReady(s):
        var commitResult = s.writeItem()
        match commitResult:
          USPMCPushComplete(c):
            discard c.extractPinned().unpin()
          USPMCPushSegmentLoaded(_):
            # Reserved-for-future arm (Task 11 §799); not emitted by current body.
            check false
          USPMCPushSegmentClosed(cl):
            discard cl.extractPinned().unpin()
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

    # Use unpinned/pin from debra - chain to avoid copy issues. Task 6:
    # startPush threads pendingItem into the chain.
    let loaded =
      startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42).loadSegment()

    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible and intact
    check loaded.segment.consumerHead.load(moRelaxed) == 0
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation. Task 7 / C-1+C5: writeItem now takes only the
    # typestate. Slot is obtained via seg.tail.fetchAdd internally — tail
    # is pre-set to 10 here, so the entry fetchAdd lands on slot 10.
    var checkResult = loaded.checkFull()
    match checkResult:
      USPMCPushSlotReady(s):
        var commitResult = s.writeItem()
        check seg.data[10] == 42 # Consume: verify write to correct slot
        check seg.tail.load(moRelaxed) == 11 # Verify tail advanced
        match commitResult:
          USPMCPushComplete(c):
            discard c.extractPinned().unpin()
          USPMCPushSegmentLoaded(_):
            # Reserved-for-future arm (Task 11 §799); not emitted by current body.
            check false
          USPMCPushSegmentClosed(cl):
            check false
            discard cl.extractPinned().unpin()
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

    var checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()
      .checkFull()

    match checkResult:
      USPMCPushSlotReady(s):
        # Task 6 / C-1: `slot` field removed from USPMCPushSlotReady.
        # Verify slot via segment.tail load (entry fetchAdd inside writeItem
        # advances it).
        check s.segment.tail.load(moRelaxed) == 0

        # Write item and VERIFY the value was written. Task 7: writeItem
        # takes only the typestate; pendingItem (42) carried from startPush.
        var commitResult = s.writeItem()
        match commitResult:
          USPMCPushComplete(c):
            discard c.extractPinned().unpin()
          USPMCPushSegmentLoaded(_):
            # Reserved-for-future arm (Task 11 §799); not emitted by current body.
            check false
          USPMCPushSegmentClosed(cl):
            check false
            discard cl.extractPinned().unpin()

        check seg.data[0] == 42 # Consume: verify write happened
        check seg.tail.load(moRelaxed) == 1 # Verify tail advanced (entry fetchAdd)
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

    var checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
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
            # Task 7: writeItem takes only the typestate; pendingItem carried
            # from startPush. Entry fetchAdd lands at slot 0 on fresh segment.
            var commitResult = s.writeItem()
            match commitResult:
              USPMCPushComplete(c):
                discard c.extractPinned().unpin()
              USPMCPushSegmentLoaded(_):
                # Reserved-for-future arm (Task 11 §799); not emitted by current body.
                check false
              USPMCPushSegmentClosed(cl):
                check false
                discard cl.extractPinned().unpin()

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

    var checkResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()
      .checkFull()

    match checkResult:
      USPMCPushSlotReady(s):
        # Task 7: writeItem takes only the typestate; pendingItem (42) from
        # startPush. Entry fetchAdd lands at slot 0 on the fresh segment.
        var commitResult = s.writeItem()
        match commitResult:
          USPMCPushComplete(c):
            discard c.extractPinned().unpin()
          USPMCPushSegmentLoaded(_):
            # Reserved-for-future arm (Task 11 §799); not emitted by current body.
            check false
          USPMCPushSegmentClosed(cl):
            check false
            discard cl.extractPinned().unpin()

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

suite "Task 11 LCRQ SPMC Segment cellState + closed fields":
  test "cellState defaults to CellEmpty for every slot (S=8)":
    type TestSeg8 = Segment[8, int]
    var seg = cast[ptr TestSeg8](alloc0(sizeof(TestSeg8)))
    # alloc0 zero-initializes; CellEmpty is uint8 0, so every cellState
    # slot must equal CellEmpty after zero-init.
    check seg.cellState[0].load(moRelaxed) == CellEmpty
    check seg.cellState[1].load(moRelaxed) == CellEmpty
    check seg.cellState[2].load(moRelaxed) == CellEmpty
    check seg.cellState[3].load(moRelaxed) == CellEmpty
    check seg.cellState[4].load(moRelaxed) == CellEmpty
    check seg.cellState[5].load(moRelaxed) == CellEmpty
    check seg.cellState[6].load(moRelaxed) == CellEmpty
    check seg.cellState[7].load(moRelaxed) == CellEmpty
    # Array length is exactly S (8).
    check seg.cellState.len == 8
    dealloc(seg)

  test "closed defaults to false":
    type TestSeg8 = Segment[8, int]
    var seg = cast[ptr TestSeg8](alloc0(sizeof(TestSeg8)))
    check seg.closed.load(moRelaxed) == false
    dealloc(seg)

suite "Task 11 USPMCPushSegmentClosed state + pendingItem propagation (Task 6)":
  test "USPMCPushSegmentClosed state declared":
    check declared(USPMCPushSegmentClosed)

  test "Ready/SegmentLoaded/SegmentFull/SlotReady/SegmentClosed all carry pendingItem: T":
    # compile-time field-presence check via doesCompile.
    check compiles(
      (
        block:
          var r: USPMCPushReady[int, 8, 4]
          r.pendingItem
      )
    )
    check compiles(
      (
        block:
          var l: USPMCPushSegmentLoaded[int, 8, 4]
          l.pendingItem
      )
    )
    check compiles(
      (
        block:
          var f: USPMCPushSegmentFull[int, 8, 4]
          f.pendingItem
      )
    )
    check compiles(
      (
        block:
          var s: USPMCPushSlotReady[int, 8, 4]
          s.pendingItem
      )
    )
    check compiles(
      (
        block:
          var c: USPMCPushSegmentClosed[int, 8, 4]
          c.pendingItem
      )
    )

  test "SlotReady has NO slot: int field (C-1 fix)":
    check not compiles(
      (
        block:
          var s: USPMCPushSlotReady[int, 8, 4]
          s.slot
      )
    )

  test "closeSegmentDone verb exists":
    check declared(closeSegmentDone)

  test "extractPinned for SegmentClosed exists":
    # extractPinned is overloaded; verify a SegmentClosed-typed call compiles.
    check compiles(
      (
        block:
          var c: USPMCPushSegmentClosed[int, 8, 4]
          discard extractPinned(c)
      )
    )

suite "Task 11 SPMC writeItem publish-CAS + Shape A retry":
  test "writeItem on empty cell publishes and transitions to Complete":
    var manager = initDebraManager[4]()
    var q = newUnboundedSipmuc[8, int, 4](addr manager)
    q.push(42)  # writeItem -> publish-CAS -> Complete
    var c = q.getConsumer()
    check c.pop().get == 42

  test "writeItem on closed cell retries via Shape A fetchAdd":
    var manager = initDebraManager[4]()
    var q = newUnboundedSipmuc[8, int, 4](addr manager)
    let segPtr = cast[ptr Segment[8, int]](headSegmentForTest(q))
    # Close cell 0 directly (simulates a consumer's prior close-CAS).
    segPtr.cellState[0].store(CellClosed, moRelaxed)
    q.push(99)
    # writeItem's entry fetchAdd lands on slot 0 (CellClosed pre-staged).
    # Publish-CAS at slot 0 fails; Shape A fetchAdd advances to slot 1.
    # Publish-CAS at slot 1 wins. Final state: tail == 2 (entry + Shape A retry).
    check segPtr.cellState[1].load(moRelaxed) == CellFilled
    check segPtr.data[1] == 99
    check segPtr.tail.load(moRelaxed) == 2  # entry fetchAdd → 1; retry fetchAdd → 2
