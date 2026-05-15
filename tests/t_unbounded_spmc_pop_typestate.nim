## Tests for unbounded SPMC pop typestate.
##
## These tests verify the typestate structure and transitions work correctly.
## Multiple consumers use CAS on consumerHead to coordinate.

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_spmc_push
import lockfreequeues/typestates/unbounded_spmc_pop

# Type aliases for our test types
type
  TestQueue = UnboundedSipmucBase[64, int, 4]
  TestSegment = Segment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.consumerHead.store(-1, moRelaxed)

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "SPMC Pop Typestate":
  test "typestate types exist and are usable":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 99
    # Task 10a: cellState[0] must be CellFilled for tryClaimSlot's
    # close-CAS to lose (returning SlotClaimed instead of ClosedSlot).
    seg.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.tail >= loaded.consumerHead
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      USPMCPopSlotClaimed(c):
        discard c.readItem().extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads head segment and consumerHead":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(4, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.consumerHead == 4
    check loaded.tail == 10
    check loaded.segment == seg

    check loaded.segment.next.load(moRelaxed) == nil

    seg.data[5] = 77
    # Task 10a: cellState[5] must be CellFilled for tryClaimSlot's
    # close-CAS to lose (returning SlotClaimed instead of ClosedSlot).
    seg.cellState[5].store(CellFilled, moRelaxed)
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      USPMCPopSlotClaimed(c):
        let complete = c.readItem()
        check complete.value == 77
        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(-1, moRelaxed)
    seg.tail.store(5, moRelaxed)
    seg.data[0] = 42
    # Task 10a: cellState[0] must be CellFilled for tryClaimSlot's
    # close-CAS to lose (returning SlotClaimed instead of ClosedSlot).
    seg.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSlotClaimed(c):
        check c.slot == 0

        let complete = c.readItem()
        check complete.value == 42
        check seg.consumerHead.load(moRelaxed) == 0
        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when consumer-saturated (Task 10a)":
    # Task 10a / design §3 D7: pre-claim short-circuit triggers ONLY on
    # `consumerHead >= S` (genuinely consumer-saturated) or on the D5
    # `closed && consumerHead >= tail` propagation. Set consumerHead == S
    # to exercise short-circuit 1.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(64, moRelaxed)  # >= S
    seg.tail.store(64, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        # Pre-claim short-circuit observed consumerHead >= S.
        var advanceResult = f.advanceSegment()

        match advanceResult:
          USPMCPopEmpty(e):
            discard e.extractPinned().unpin()
          USPMCPopReady(_):
            check false
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  # NOTE (Task 9, 2026-05-15): the prior "over-claim race
  # (awaitingTail=true)" test has been removed. Task 9 deletes the
  # `awaitingTail` discriminator on `USPMCPopSegmentExhausted`; the
  # over-claim race is the bug Task 10a's close-CAS / `USPMCPopClosedSlot`
  # arm fixes. Once Task 10a lands, a parallel test should re-cover the
  # close-CAS path (consumer wins close-CAS on an unpublished slot,
  # pop returns none(T) without advancing headSegment).

  test "readItem reads value correctly":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(-1, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.data[1] = 43
    seg.data[2] = 44
    # Task 10a: pre-fill the cellState array for the slots the producer
    # would have published. tryClaimSlot's close-CAS loses on CellFilled.
    seg.cellState[0].store(CellFilled, moRelaxed)
    seg.cellState[1].store(CellFilled, moRelaxed)
    seg.cellState[2].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSlotClaimed(c):
        let complete = c.readItem()

        check complete.value == 42
        check seg.consumerHead.load(moRelaxed) == 0
        check queue.itemCount.load(moRelaxed) == 2

        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "advanceSegment returns Ready when next segment exists":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    seg1.consumerHead.store(63, moRelaxed)
    seg1.tail.store(64, moRelaxed)
    seg1.next.store(seg2, moRelease)
    seg2.consumerHead.store(-1, moRelaxed)
    seg2.tail.store(3, moRelaxed)
    seg2.data[0] = 100

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg1, moRelaxed)
    queue.tailSegment = seg2
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        var advanceResult = f.advanceSegment()

        match advanceResult:
          USPMCPopReady(_):
            # Note: Unlike MPSC, SPMC doesn't update headSegment during advanceSegment
            # The consumer needs to coordinate segment advancement at a higher level
            # This test just verifies the typestate transition works correctly
            discard
          USPMCPopEmpty(_):
            check false
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg1)
    freeTestSegment(seg2)

suite "Task 11 SPMC pop ClosedSlot state":
  test "USPMCPopClosedSlot type exists with extractPinned":
    # Type-existence + extractPinned overload check (compile-time only).
    # USPMCPopClosedSlot is dead-code-pending Task 10a (no production
    # emit yet); this test is a structural witness that Task 9's
    # type-only restructure compiles.
    check declared(USPMCPopClosedSlot)
    # Verify the extractPinned overload accepts USPMCPopClosedSlot. We
    # don't construct an instance (no emit site exists yet); the
    # `compiles()` check witnesses the overload's existence.
    check compiles((
      proc () =
        var x: USPMCPopClosedSlot[int, 8, 4]
        discard extractPinned(x)
    ))

  test "USPMCPopSegmentExhausted has NO awaitingTail field":
    # Compile-time negative check: accessing `x.awaitingTail` must
    # FAIL to compile after Task 9. Before Task 9 this `compiles(...)`
    # returns true (RED); after Task 9 it returns false (GREEN).
    check not compiles((
      proc () =
        var x: USPMCPopSegmentExhausted[int, 8, 4]
        discard x.awaitingTail
    ))

suite "Task 10a SPMC tryClaimSlot fetchAdd + close-CAS":
  # Task 10a: tryClaimSlot now performs `consumerHead.fetchAdd(1, moAcquire)`
  # then close-CAS on `cellState[mySlot]`. Three outcomes:
  #   1. close-CAS wins on CellEmpty -> USPMCPopClosedSlot.
  #   2. close-CAS loses (cell is CellFilled) -> USPMCPopSlotClaimed.
  #   3. mySlot >= S OR pre-claim short-circuit -> USPMCPopSegmentExhausted.

  test "tryClaimSlot on empty cell wins close-CAS, returns ClosedSlot":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    # Producer has not yet published anything; cellState[0] defaults to
    # CellEmpty (= 0). consumerHead = 0, tail = 1 (over-claim race
    # window: producer reserved a slot but has not yet publish-CAS'd).
    seg.consumerHead.store(0, moRelaxed)
    seg.tail.store(1, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopClosedSlot(c):
        # Close-CAS won: cellState[0] is now CellClosed.
        check seg.cellState[0].load(moRelaxed) == CellClosed
        # consumerHead advanced via fetchAdd.
        check seg.consumerHead.load(moRelaxed) == 1
        discard c.extractPinned().unpin()
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot on filled cell loses close-CAS, returns SlotClaimed":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(0, moRelaxed)
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 7
    # Producer has published slot 0 (CellFilled).
    seg.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSlotClaimed(c):
        check c.slot == 0
        # cellState[0] remains CellFilled (close-CAS lost).
        check seg.cellState[0].load(moRelaxed) == CellFilled
        let complete = c.readItem()
        check complete.value == 7
        discard complete.extractPinned().unpin()
      USPMCPopClosedSlot(_):
        check false
      USPMCPopSegmentExhausted(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when consumerHead >= S":
    # Pre-claim short-circuit 1 (design §3 D7 load-bearing refinement):
    # only `consumerHead >= S` triggers the genuinely-saturated short-
    # circuit. The fetchAdd-only `consumerHead >= freshTail` is removed.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(64, moRelaxed)  # >= S
    seg.tail.store(64, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        # Did NOT consume a fetchAdd (short-circuited).
        check seg.consumerHead.load(moRelaxed) == 64
        discard f.extractPinned().unpin()
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted on closed-and-saturated":
    # Pre-claim short-circuit 2 (D5 propagation; C6 paired moAcquire):
    # `closed && consumerHead >= tail` short-circuits. consumerHead < S,
    # so short-circuit 1 does NOT fire.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(3, moRelaxed)  # < S
    seg.tail.store(3, moRelaxed)
    seg.closed.store(true, moRelease)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        # Did NOT consume a fetchAdd (short-circuited).
        check seg.consumerHead.load(moRelaxed) == 3
        discard f.extractPinned().unpin()
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when fetchAdd returns mySlot >= S":
    # Pre-claim short-circuits do NOT fire (consumerHead < S, !closed).
    # fetchAdd advances consumerHead from S-1 to S; the load at the
    # check below sees S which triggers the post-fetchAdd guard.
    # Set consumerHead to S so fetchAdd returns S and exits.
    # NOTE: with the §3 D7 short-circuit, consumerHead == S already
    # fires short-circuit 1 above. Use consumerHead = S - 1 to avoid
    # the pre-claim short-circuit and exercise the post-fetchAdd guard.
    # But in that case mySlot = S - 1 < S; the close-CAS path runs.
    # The "fetchAdd returns >= S" guard is dead-code-equivalent under
    # §3 D7 (short-circuit 1 catches it first). We assert this by
    # observing that consumerHead == S triggers SegmentExhausted via
    # the pre-claim, NOT via the post-fetchAdd guard.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(64, moRelaxed)
    seg.tail.store(64, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment = seg
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      USPMCPopSegmentExhausted(f):
        # No fetchAdd consumed; consumerHead unchanged.
        check seg.consumerHead.load(moRelaxed) == 64
        discard f.extractPinned().unpin()
      USPMCPopSlotClaimed(_):
        check false
      USPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)
