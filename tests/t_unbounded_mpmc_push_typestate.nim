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
