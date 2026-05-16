## Tests for unbounded MPMC pop typestate.
##
## Task 14 LCRQ migration: these tests verify the typestate structure
## and transitions work correctly after the `committed[] -> cellState[]`
## rename, the addition of segment-level `closed: Atomic[bool]`, and the
## state-graph reshape (removal of UMPMCPopSlotUncommitted and the
## UMPMCPopCommitCheck union; addition of UMPMCPopClosedSlot as a
## TYPE-ONLY state). MPMC pop uses wait-free fetchAdd on `consumerHead`
## (Task 11 framing-flip: counter is next-claimable, starts at 0); Task
## 16 will introduce the close-CAS-on-empty branch in `tryClaimSlot`
## that emits `UMPMCPopClosedSlot`. At Task 14, tryClaimSlot emits only
## SlotClaimed (in-range fetchAdd) or SegmentExhausted (saturated).

import unittest2
import lockfreequeues/atomic_dsl
import debra

import lockfreequeues/typestates/unbounded_mpmc_push
import lockfreequeues/typestates/unbounded_mpmc_pop

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

suite "MPMC Pop Typestate":
  test "typestate types exist and are usable":
    # Verify state types exist and fields are accessible
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.tail.store(1, moRelaxed)
    seg.data[0] = 99
    seg.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(1, moRelaxed)
    queue.segments.store(1, moRelaxed)

    # Actually use the types with real data
    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    # Verify fields are accessible and have valid values
    check loaded.consumerHead == 0
    check loaded.tail >= loaded.consumerHead
    check loaded.segment != nil
    check loaded.segment.data[0] == 99

    # Clean up
    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPopSlotClaimed(c):
        let complete = c.readItem()
        discard complete.extractPinned().unpin()
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopClosedSlot(_):
        check false
    freeTestSegment(seg)

  test "loadSegment loads head segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(5, moRelaxed)
    seg.tail.store(10, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    let loaded = startPop[int, 64, 4](unpinned(handle).pin(), addr queue).loadSegment()

    check loaded.consumerHead == 5
    check loaded.tail == 10
    check loaded.segment == seg

    # Verify segment structure is accessible
    check loaded.segment.next.load(moRelaxed) == nil

    # Complete operation and VERIFY value read
    seg.data[5] = 77
    seg.cellState[5].store(CellFilled, moRelaxed)

    var claimResult = loaded.tryClaimSlot()
    match claimResult:
      UMPMCPopSlotClaimed(claimed):
        check claimed.slot == 5
        let complete = claimed.readItem()
        check complete.value == 77
        discard complete.extractPinned().unpin()
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SlotClaimed when fetchAdd succeeds":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(0, moRelaxed)
    seg.tail.store(5, moRelaxed)
    seg.data[0] = 42
    seg.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(5, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSlotClaimed(c):
        check c.slot == 0

        # Read item and VERIFY value
        let complete = c.readItem()
        check complete.value == 42
        # consumerHead is next-claimable: after a successful fetchAdd(1) at
        # 0, the value is 1 (the slot the next claimant will reserve).
        check seg.consumerHead.load(moRelaxed) == 1
        discard complete.extractPinned().unpin()
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "tryClaimSlot returns SegmentExhausted when no items":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    # consumerHead == tail == 5: all 5 slots already claimed.
    seg.consumerHead.store(5, moRelaxed)
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSegmentExhausted(f):
        # Try to advance - should return Empty since no next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPMCPopEmpty(e):
            # Verify queue state remains consistent
            check queue.itemCount.load(moRelaxed) == 0

            discard e.extractPinned().unpin()
          UMPMCPopReady(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "readItem reads value from claimed slot":
    # Task 14 LCRQ: SlotClaimed -> Complete is now a DIRECT transition
    # (no UMPMCPopCommitCheck union). The defensive cellState double-
    # check in readItem becomes load-bearing once Task 16 lands the
    # close-CAS HB chain in tryClaimSlot; at Task 14 readItem simply
    # reads `seg.data[slot]` and emits Complete.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    seg.consumerHead.store(0, moRelaxed)
    seg.tail.store(3, moRelaxed)
    seg.data[0] = 42
    seg.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSlotClaimed(c):
        check c.slot == 0
        let complete = c.readItem()
        check complete.value == 42
        check complete.slot == 0
        check seg.consumerHead.load(moRelaxed) == 1
        check queue.itemCount.load(moRelaxed) == 2

        discard complete.extractPinned().unpin()
      UMPMCPopSegmentExhausted(_):
        check false
      UMPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "advanceSegment returns Ready when next segment exists":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg1 = newTestSegment()
    var seg2 = newTestSegment()
    # seg1 fully consumed: consumerHead == tail == 64.
    seg1.consumerHead.store(64, moRelaxed)
    seg1.tail.store(64, moRelaxed)
    seg1.next.store(seg2, moRelease)
    seg2.consumerHead.store(0, moRelaxed)
    seg2.tail.store(3, moRelaxed)
    seg2.data[0] = 100
    seg2.cellState[0].store(CellFilled, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg1, moRelaxed)
    queue.tailSegment.store(seg2, moRelaxed)
    queue.itemCount.store(3, moRelaxed)
    queue.segments.store(2, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSegmentExhausted(f):
        # Advance to next segment
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPMCPopReady(r):
            # Now load and read from the new segment
            let loaded2 = r.loadSegment()
            check loaded2.segment == seg1 # MPMC doesn't update headSegment
          UMPMCPopEmpty(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg1)
    freeTestSegment(seg2)

  test "advanceSegment returns Empty when no next segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)

    var seg = newTestSegment()
    # Segment fully consumed: consumerHead == tail == 5.
    seg.consumerHead.store(5, moRelaxed)
    seg.tail.store(5, moRelaxed)

    var queue: TestQueue
    queue.manager = addr manager
    queue.headSegment.store(seg, moRelaxed)
    queue.tailSegment.store(seg, moRelaxed)
    queue.itemCount.store(0, moRelaxed)
    queue.segments.store(1, moRelaxed)

    var claimResult = startPop[int, 64, 4](unpinned(handle).pin(), addr queue)
      .loadSegment()
      .tryClaimSlot()

    match claimResult:
      UMPMCPopSegmentExhausted(f):
        var advanceResult = f.advanceSegment()

        match advanceResult:
          UMPMCPopEmpty(e):
            discard e.extractPinned().unpin()
          UMPMCPopReady(_):
            check false
      UMPMCPopSlotClaimed(_):
        check false
      UMPMCPopClosedSlot(_):
        check false

    freeTestSegment(seg)

  test "UMPMCPopClosedSlot match-arm exists (TYPE-ONLY at Task 14)":
    # Task 14: UMPMCPopClosedSlot is declared TYPE-ONLY (no production
    # code path emits it yet — Task 16 introduces the close-CAS-on-empty
    # branch in tryClaimSlot). This test verifies the state can be
    # hand-constructed and the extractPinned overload resolves correctly.
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue: TestQueue
    queue.manager = addr manager

    let pinned = unpinned(handle).pin()
    let closedSlot = UMPMCPopClosedSlot[int, 64, 4](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: addr queue,
    )
    discard closedSlot.extractPinned().unpin()
