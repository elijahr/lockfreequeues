## Tests for unbounded MPMC push typestate.
##
## Task 14 LCRQ migration: these tests verify the typestate structure
## and transitions after the `committed[] -> cellState[]` rename, the
## addition of segment-level `closed: Atomic[bool]`, the propagation of
## `pendingItem: T` through every push state (C4), and the new
## `writeItem` signature (`(claimed: sink UMPMCPushSlotClaimed)
## -> UMPMCPushCommitResult`; pulls `pendingItem` from claimed
## internally — there is NO `item: sink T` parameter). MPMC's writeItem
## also has NO entry fetchAdd (C-1 asymmetry vs SPMC): the initial slot
## comes from `claimed.slot` (set by tryClaimSlot's reservation CAS);
## Shape A retry uses `seg.tail.fetchAdd(1, moRelaxed)` to obtain fresh
## slots on publish-CAS failure.
##
## Single-thread tests: writeItem's publish-CAS targets `cellState[slot]`,
## which is initialized to CellEmpty (0'u8) by `alloc0`. With no
## concurrent close-CAS contention, every publish-CAS wins on first
## attempt and emits `UMPMCPushComplete` without entering the Shape A
## retry loop.

import unittest2
import std/options
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_mpmc_push
import lockfreequeues/unbounded_mupmuc

# Type aliases for our test types
type
  TestQueue = UnboundedMupmucBase[64, int, 4]
  TestSegment = UMPMCSegment[64, int]

# Test segment allocation
proc newTestSegment(): ptr TestSegment =
  result = cast[ptr TestSegment](alloc0(sizeof(TestSegment)))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.consumerHead.store(0, moRelaxed)
  # alloc0 zeroes the block, so cellState[] starts at CellEmpty (0'u8) and
  # `closed` at false. No explicit init loop required for those fields.

proc freeTestSegment(seg: ptr TestSegment) =
  dealloc(seg)

suite "MPMC Push Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data. Task 14: startPush takes
    # pendingItem.
    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 0)
      .loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.tail >= 0
    check loaded.segment != nil
    check loaded.segment.consumerHead.load(moRelaxed) == 0
    check loaded.segment.next.load(moRelaxed) == nil

    # Clean up
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPushSlotClaimed(c):
        var commit = c.writeItem()
        match commit:
          UMPMCPushComplete(done):
            discard done.extractPinned().unpin()
          UMPMCPushSegmentLoaded(_):
            check false
          UMPMCPushSegmentClosed(_):
            check false
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
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
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()

    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible and intact
    check loaded.segment.consumerHead.load(moRelaxed) == 0
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPushSlotClaimed(c):
        # writeItem consumes pendingItem (42, threaded from startPush).
        var commit = c.writeItem()
        match commit:
          UMPMCPushComplete(done):
            check seg.data[10] == 42 # Verify write to correct slot
            check seg.cellState[10].load(moRelaxed) == CellFilled
            check seg.tail.load(moRelaxed) == 11 # Verify tail advanced
            check queue.itemCount.load(moRelaxed) == 1
            discard done.extractPinned().unpin()
          UMPMCPushSegmentLoaded(_):
            check false
          UMPMCPushSegmentClosed(_):
            check false
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when CAS succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSlotClaimed(c):
        check c.slot == 0

        var commit = c.writeItem()
        match commit:
          UMPMCPushComplete(done):
            check seg.data[0] == 42
            check seg.cellState[0].load(moRelaxed) == CellFilled
            check seg.tail.load(moRelaxed) == 1
            check queue.itemCount.load(moRelaxed) == 1
            discard done.extractPinned().unpin()
          UMPMCPushSegmentLoaded(_):
            check false
          UMPMCPushSegmentClosed(_):
            check false
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentFull when segment full":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed) # Full segment

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()
      .tryClaimSlot()

    # Allocate new segment and retry. The standalone `allocateNewSegment`
    # transition variant was removed (verb-count consolidation); the
    # tuple-returning `tryAllocateNewSegment` is the single canonical
    # form. We discard the `allocated` bit here because this test stages
    # an uncontested allocation (no peer thread); it always wins.
    var newSeg = newTestSegment()
    match claimResult:
      UMPMCPushSegmentFull(f):
        let (ready2, _) = f.tryAllocateNewSegment(newSeg)
        var claimResult2 = ready2.loadSegment().tryClaimSlot()

        match claimResult2:
          UMPMCPushSlotClaimed(c):
            var commit = c.writeItem()
            match commit:
              UMPMCPushComplete(done):
                # Verify write went to NEW segment, not old one
                check newSeg.data[0] == 42
                check newSeg.cellState[0].load(moRelaxed) == CellFilled
                check newSeg.tail.load(moRelaxed) == 1
                check seg.next.load(moRelaxed) == newSeg # Segments correctly linked
                check seg.tail.load(moRelaxed) == 64 # Old segment unchanged
                discard done.extractPinned().unpin()
              UMPMCPushSegmentLoaded(_):
                check false
              UMPMCPushSegmentClosed(_):
                check false
          UMPMCPushSegmentFull(_):
            check false
          UMPMCPushReady(_):
            check false
      UMPMCPushSlotClaimed(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)
    freeTestSegment(newSeg)

  test "tryClaimSlot returns Ready when CAS fails (retry path)":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Load segment with tail=5
    let loaded = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 99)
      .loadSegment()

    check loaded.tail == 5

    # Simulate another thread advancing tail (race condition)
    discard seg.tail.fetchAdd(1, moRelaxed) # Now tail is 6

    # tryClaimSlot should detect CAS failure and return Ready for retry
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPushReady(r):
        # I-5: the Ready arm of tryClaimSlot propagates pendingItem (99)
        # into the rebuilt Ready so the race-loser preserves its item.
        check r.pendingItem == 99
        var pending = r.pendingItem
        var rebuilt = UMPMCPushReady[int, 64, 4](
          pinnedHandle: r.pinnedHandle,
          pinnedEpoch: r.pinnedEpoch,
          queue: r.queue,
          pendingItem: move(pending),
        )
        # Clean up - do a successful operation
        var claimResult2 = rebuilt.loadSegment().tryClaimSlot()
        match claimResult2:
          UMPMCPushSlotClaimed(c):
            var commit = c.writeItem()
            match commit:
              UMPMCPushComplete(done):
                check seg.data[6] == 99
                check seg.cellState[6].load(moRelaxed) == CellFilled
                discard done.extractPinned().unpin()
              UMPMCPushSegmentLoaded(_):
                check false
              UMPMCPushSegmentClosed(_):
                check false
          UMPMCPushSegmentFull(_):
            check false
          UMPMCPushReady(_):
            check false
      UMPMCPushSlotClaimed(_):
        check false
      UMPMCPushSegmentFull(_):
        check false

    freeTestSegment(seg)

  test "allocateNewSegment handles allocation race":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(64, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Simulate another thread already linked a segment
    var seg2 = newTestSegment()
    seg.next.store(seg2, moRelease)

    # Now try to allocate our own segment
    var seg3 = newTestSegment()
    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSegmentFull(f):
        # Use tryAllocateNewSegment to detect the race
        let (ready, allocated) = f.tryAllocateNewSegment(seg3)

        check allocated == false # Lost the race, another thread allocated

        # Should still work - retry and use the winner's segment
        var claimResult2 = ready.loadSegment().tryClaimSlot()
        match claimResult2:
          UMPMCPushSlotClaimed(c):
            var commit = c.writeItem()
            match commit:
              UMPMCPushComplete(done):
                # Should have written to seg2 (winner's segment), not seg3
                check seg2.data[0] == 42
                check seg2.cellState[0].load(moRelaxed) == CellFilled
                discard done.extractPinned().unpin()
              UMPMCPushSegmentLoaded(_):
                check false
              UMPMCPushSegmentClosed(_):
                check false
          UMPMCPushSegmentFull(_):
            check false
          UMPMCPushReady(_):
            check false
      UMPMCPushSlotClaimed(_):
        check false
      UMPMCPushReady(_):
        check false

    # Clean up - seg3 should be freed by caller since allocation failed
    freeTestSegment(seg)
    freeTestSegment(seg2)
    freeTestSegment(seg3)

  test "writeItem writes data and publishes via cellState publish-CAS":
    # Task 14 LCRQ: writeItem performs the publish-CAS itself
    # (CellEmpty -> CellFilled) and emits UMPMCPushComplete on success.
    # The prior two-step (writeItem -> ItemWritten -> markCommitted ->
    # Complete) pipeline is gone; there is no intermediate ItemWritten
    # state.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 42)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPushSlotClaimed(c):
        var commit = c.writeItem()
        match commit:
          UMPMCPushComplete(done):
            # Data written and cellState published in a single verb.
            check seg.data[0] == 42
            check seg.cellState[0].load(moRelaxed) == CellFilled
            check queue.itemCount.load(moRelaxed) == 1
            discard done.extractPinned().unpin()
          UMPMCPushSegmentLoaded(_):
            check false
          UMPMCPushSegmentClosed(_):
            check false
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    freeTestSegment(seg)

  test "Task 11 MPMC end-to-end smoke (push 10, pop 10 single-thread)":
    # Plan §1770-1781: bundled-commit smoke for the facade reshape. Uses
    # the real facade (not raw typestate plumbing) to verify push/pop
    # round-trip on a fresh queue.
    var manager = initDebraManager[4]()
    var q: UnboundedMupmuc[8, int, 4]
    q = newUnboundedMupmuc[8, int, 4](addr manager)
    var producer = q.getProducer()
    var consumer = q.getConsumer()
    for i in 1 .. 10:
      producer.push(i)
    var popped: seq[int]
    for i in 1 .. 10:
      let got = consumer.pop()
      check got.isSome
      popped.add(got.get)
    check popped == @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

suite "Task 18 MPMC closure-storm: writeItem Shape A retry + SegmentClosed escalation":
  ## Plan §1956 (Task 18): the MPMC counterpart to SPMC's
  ## `tests/t_unbounded_spmc_push_typestate.nim:373` closure-storm test.
  ##
  ## Three closure-storm tests, each pinning a distinct ESCAPE path:
  ##   1. Shape A retry path (slot 0 pre-closed → publish lands at slot 1).
  ##      Green-mirage: removing `seg.tail.fetchAdd(1, moRelaxed)` from
  ##      `writeItem` MUST flip this test to FAIL (the retry would
  ##      escalate to SegmentClosed immediately on the first publish-CAS
  ##      failure instead of advancing to slot 1).
  ##   2. SegmentClosed escalation from `writeItem` typestate verb
  ##      (every slot pre-closed → publish-CAS fails S times → escalate).
  ##      Asserts the returned variant is `UMPMCPushSegmentClosed` and
  ##      carries the pendingItem forward. Green-mirage: an absent
  ##      escalation branch in `writeItem` would either hang or assert.
  ##   3. Facade-level closure-storm via `unbounded_mupmuc.push`
  ##      (every slot of the head segment pre-closed → facade dispatches
  ##      `UMPMCPushSegmentClosed`, rotates to a fresh segment via
  ##      `closeSegmentDone -> tryAllocateNewSegment`, retries publish).
  ##      Asserts: (a) the new segment is linked (segmentCount goes
  ##      1 → 2); (b) the item is observable via `pop`; (c) the old
  ##      segment's `closed` flag is true. Green-mirage: replacing the
  ##      facade's `UMPMCPushSegmentClosed(closedState)` arm with
  ##      `discard` + return would silently drop the item — both the
  ##      `pop` assertion and the segmentCount assertion would FAIL.

  test "writeItem on closed cell retries via Shape A fetchAdd":
    # Mirror of SPMC test at tests/t_unbounded_spmc_push_typestate.nim:373.
    # Pre-close slot 0; push(99). The reservation CAS in tryClaimSlot
    # advances tail 0→1 and yields slot=0 (CellClosed pre-staged).
    # publish-CAS at slot 0 fails (expected CellEmpty, observed
    # CellClosed). Shape A retry: seg.tail.fetchAdd(1, moRelaxed) →
    # myTailSlot=1, tail→2. publish-CAS at slot 1 wins (cellState[1]
    # was CellEmpty). Final state: tail==2, cellState[1]==CellFilled,
    # data[1]==99, segmentCount==1 (no rotation).
    var manager = initDebraManager[4]()
    var q: UnboundedMupmuc[8, int, 4]
    q = newUnboundedMupmuc[8, int, 4](addr manager)
    let segPtr = cast[ptr UMPMCSegment[8, int]](headSegmentForTest(q))
    # Close cell 0 directly (simulates a consumer's prior close-CAS).
    segPtr.cellState[0].store(CellClosed, moRelaxed)
    var producer = q.getProducer()
    producer.push(99)
    # tail moved 0 → 1 (reservation CAS) → 2 (Shape A fetchAdd).
    check segPtr.tail.load(moRelaxed) == 2
    check segPtr.cellState[0].load(moRelaxed) == CellClosed
    check segPtr.cellState[1].load(moRelaxed) == CellFilled
    check segPtr.data[1] == 99
    check segPtr.closed.load(moRelaxed) == false
    check q.segmentCount == 1  # no rotation; Shape A retry stayed in-segment

  test "writeItem on fully-closed segment escalates to UMPMCPushSegmentClosed":
    # Typestate-level direct test: drive writeItem against a segment
    # whose entire cellState[] array is pre-staged to CellClosed. Every
    # publish-CAS fails; Shape A retry advances myTailSlot S times;
    # closureRetryCount reaches StarvingThreshold = S; writeItem T&Ss
    # `seg.closed` and returns UMPMCPushSegmentClosed with pendingItem
    # preserved.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    # Pre-close every cell in the segment.
    for i in 0 ..< 64:
      seg.cellState[i].store(CellClosed, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPush[int, 64, 4](unpinned(handle).pin(), addr queue, 777)
      .loadSegment()
      .tryClaimSlot()

    var observedSegmentClosed = false
    var observedPending = 0
    var observedSegPtr: ptr UMPMCSegment[64, int] = nil
    match claimResult:
      UMPMCPushSlotClaimed(c):
        var commit = c.writeItem()
        match commit:
          UMPMCPushSegmentClosed(closedState):
            observedSegmentClosed = true
            observedPending = closedState.pendingItem
            observedSegPtr = closedState.segment
            discard closedState.extractPinned().unpin()
          UMPMCPushComplete(_):
            check false
          UMPMCPushSegmentLoaded(_):
            check false
      UMPMCPushSegmentFull(_):
        check false
      UMPMCPushReady(_):
        check false

    check observedSegmentClosed == true
    check observedPending == 777
    check observedSegPtr == seg
    # writeItem's escalation branch T&S'd seg.closed to true.
    check seg.closed.load(moRelaxed) == true
    # tail advanced to S (entry reservation + (S-1) Shape A fetchAdds).
    # Reservation CAS: 0 → 1. The escalation check is
    # `closureRetryCount >= StarvingThreshold` BEFORE the Shape A
    # fetchAdd of that iteration, so tail advances exactly S-1 times
    # via Shape A before escalation: tail == 1 + (S-1) == S.
    check seg.tail.load(moRelaxed) == 64
    freeTestSegment(seg)

  test "facade push on fully-closed segment dispatches SegmentClosed arm and rotates":
    # End-to-end closure-storm via the facade. Pre-close every cell in
    # the head segment. push(42) dispatches:
    #   tryClaimSlot CAS (slot 0) → SlotClaimed → writeItem (S retries,
    #   all fail) → SegmentClosed → facade arm: closeSegmentDone →
    #   tryAllocateNewSegment (alloc wins, new segment linked) → loop →
    #   loadSegment → tryClaimSlot on new segment → writeItem (slot 0
    #   CellEmpty, publish-CAS wins) → Complete.
    #
    # Acceptance evidence:
    #   - segmentCount goes 1 → 2 (new segment linked).
    #   - Old segment.closed flag is true.
    #   - pop returns the pushed item (no item loss across SegmentClosed
    #     arm dispatch).
    var manager = initDebraManager[4]()
    var q: UnboundedMupmuc[8, int, 4]
    q = newUnboundedMupmuc[8, int, 4](addr manager)
    let oldSegPtr = cast[ptr UMPMCSegment[8, int]](headSegmentForTest(q))
    # Pre-close every cell on the head segment. Bump consumerHead to S
    # so the consumer's tryClaimSlot will treat every slot as "already
    # claimed" and skip the segment cleanly (consumer's close-CAS only
    # fires on cells at-or-after consumerHead — the pre-closed cells
    # below consumerHead are off-limits to the consumer's close-CAS
    # path, mirroring production where consumer-emitted CellClosed
    # always trails consumerHead's advance).
    for i in 0 ..< 8:
      oldSegPtr.cellState[i].store(CellClosed, moRelaxed)
    oldSegPtr.consumerHead.store(8, moRelaxed)

    check q.segmentCount == 1
    check oldSegPtr.closed.load(moRelaxed) == false

    var producer = q.getProducer()
    producer.push(42)

    # SegmentClosed arm executed: facade rotated to a new segment.
    check q.segmentCount == 2
    check oldSegPtr.closed.load(moRelaxed) == true
    # The new segment is reachable via oldSeg.next.
    let newSegRaw = oldSegPtr.next.load(moAcquire)
    check newSegRaw != nil
    let newSegPtr = cast[ptr UMPMCSegment[8, int]](newSegRaw)
    # publish-CAS landed at slot 0 of the new segment (CellEmpty start).
    check newSegPtr.cellState[0].load(moRelaxed) == CellFilled
    check newSegPtr.data[0] == 42

    # Item is observable via pop (round-trip across SegmentClosed
    # dispatch + new-segment rotation).
    var consumer = q.getConsumer()
    let got = consumer.pop()
    check got.isSome
    check got.get == 42
    # Queue drained.
    check consumer.pop().isNone
