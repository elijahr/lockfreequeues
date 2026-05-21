## Typestate for unbounded MPSC push operations.
##
## Bridges from DEBRA's Pinned[MT, CC] state, performs push with CAS coordination,
## bridges back. Multiple producers coordinate via CAS on tail pointer.

import ../atomic_dsl
import typestates
import debra

type
  # Segment type for MPSC - has committed flags
  MPSCSegment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr MPSCSegment[S, T]]
    tail*: Atomic[int] # CAS coordination for producers
    head*: int # Consumer read position (single consumer, no atomic)
    committed*: array[S, Atomic[bool]] # Track which slots are ready to read

  # Base queue type for MPSC
  # CC = ccSingle — single-consumer queue, so the nim-debra pin/retire
  # contract is the single-consumer (no-race) form.
  UnboundedMupsicBase*[
    S: static int, T; MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
  ] = object
    manager*: ptr DebraManager[MaxThreads, CC]
    headSegment*: ptr MPSCSegment[S, T]
    tailSegment*: Atomic[ptr MPSCSegment[S, T]] # Atomic for CAS
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  MPSCPushContext*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]

  # States
  MPSCPushReady*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct MPSCPushContext[T, S, MT, CC]

  MPSCPushSegmentLoaded*[
    T; S, MT: static int, CC: static PinScopeCardinality = ccSingle
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]
    tail*: int

  MPSCPushSegmentFull*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]

  MPSCPushSlotClaimed*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]
    slot*: int

  MPSCPushItemWritten*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]
    slot*: int

  MPSCPushComplete*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]

typestate MPSCPushContext[
  T, S: static int, MT: static int, CC: static PinScopeCardinality
]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  defaults:
    CC:
      ccSingle
  states MPSCPushReady[T, S, MT, CC],
    MPSCPushSegmentLoaded[T, S, MT, CC],
    MPSCPushSegmentFull[T, S, MT, CC],
    MPSCPushSlotClaimed[T, S, MT, CC],
    MPSCPushItemWritten[T, S, MT, CC],
    MPSCPushComplete[T, S, MT, CC]
  transitions:
    MPSCPushReady[T, S, MT, CC] -> MPSCPushSegmentLoaded[T, S, MT, CC]
    MPSCPushSegmentLoaded[T, S, MT, CC] ->
      (
        MPSCPushSlotClaimed[T, S, MT, CC] | MPSCPushSegmentFull[T, S, MT, CC] |
        MPSCPushReady[T, S, MT, CC]
      ) as MPSCSlotClaimResult[T, S, MT, CC]
    MPSCPushSegmentFull[T, S, MT, CC] -> MPSCPushReady[T, S, MT, CC]
    MPSCPushSlotClaimed[T, S, MT, CC] -> MPSCPushItemWritten[T, S, MT, CC]
    MPSCPushItemWritten[T, S, MT, CC] -> MPSCPushComplete[T, S, MT, CC]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int, CC: static PinScopeCardinality](
    pinned: sink Pinned[MT, CC], queue: ptr UnboundedMupsicBase[S, T, MT, CC]
): MPSCPushReady[T, S, MT, CC] =
  ## Create push context from DEBRA's Pinned state.
  MPSCPushReady[T, S, MT, CC](
    MPSCPushContext[T, S, MT, CC](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from MPSCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: sink MPSCPushComplete[T, S, MT, CC]
): Pinned[MT, CC] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: complete.pinnedHandle, epoch: complete.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    ready: sink MPSCPushReady[T, S, MT, CC]
): MPSCPushSegmentLoaded[T, S, MT, CC] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = MPSCPushContext[T, S, MT, CC](ready)
  let seg = ctx.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  MPSCPushSegmentLoaded[T, S, MT, CC](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int, CC: static PinScopeCardinality](
    loaded: sink MPSCPushSegmentLoaded[T, S, MT, CC]
): MPSCSlotClaimResult[T, S, MT, CC] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  let tail = loaded.tail

  if tail >= S:
    return
      MPSCSlotClaimResult[T, S, MT, CC] ->
      MPSCPushSegmentFull[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Try CAS
  var expected = tail
  if loaded.segment.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
    # Won the slot
    return
      MPSCSlotClaimResult[T, S, MT, CC] ->
      MPSCPushSlotClaimed[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: tail,
      )
  else:
    # CAS failed - retry from beginning
    return
      MPSCSlotClaimResult[T, S, MT, CC] ->
      MPSCPushReady[T, S, MT, CC](
        MPSCPushContext[T, S, MT, CC](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Handle segment full - allocate new segment
proc allocateNewSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    full: sink MPSCPushSegmentFull[T, S, MT, CC], newSegment: ptr MPSCSegment[S, T]
): MPSCPushReady[T, S, MT, CC] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  ## Caller must allocate the segment before calling.
  # Check if someone else already linked a segment
  let nextSeg = full.segment.next.load(moAcquire)
  if nextSeg != nil:
    # Someone else allocated, just advance
    var expectedSeg = full.segment
    discard
      full.queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
  else:
    # Try to link our new segment
    var expectedNext: ptr MPSCSegment[S, T] = nil
    if full.segment.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
      # Won the allocation race
      var expectedSeg = full.segment
      discard full.queue.tailSegment.compareExchange(
        expectedSeg, newSegment, moRelease, moRelaxed
      )
      discard full.queue.segments.fetchAdd(1, moRelaxed)
    else:
      # Lost race - try to advance using whatever segment won
      let winnerSeg = full.segment.next.load(moAcquire)
      if winnerSeg != nil:
        var expectedSeg = full.segment
        discard full.queue.tailSegment.compareExchange(
          expectedSeg, winnerSeg, moRelease, moRelaxed
        )

  MPSCPushReady[T, S, MT, CC](
    MPSCPushContext[T, S, MT, CC](
      pinnedHandle: full.pinnedHandle, pinnedEpoch: full.pinnedEpoch, queue: full.queue
    )
  )

# Helper that returns allocation status (for callers who need to know if they should free newSegment)
proc tryAllocateNewSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    full: sink MPSCPushSegmentFull[T, S, MT, CC], newSegment: ptr MPSCSegment[S, T]
): tuple[ready: MPSCPushReady[T, S, MT, CC], allocated: bool] =
  ## Try to link new segment using CAS.
  ## Returns (ready state, true if we allocated, false if someone else did).
  ## This is a non-transition helper that wraps allocateNewSegment.
  # Check if someone else already linked a segment
  let nextSeg = full.segment.next.load(moAcquire)
  if nextSeg != nil:
    # Someone else allocated, just advance
    var expectedSeg = full.segment
    discard
      full.queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
    return (
      MPSCPushReady[T, S, MT, CC](
        MPSCPushContext[T, S, MT, CC](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

  # Try to link our new segment
  var expectedNext: ptr MPSCSegment[S, T] = nil
  if full.segment.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
    # Won the allocation race
    var expectedSeg = full.segment
    discard full.queue.tailSegment.compareExchange(
      expectedSeg, newSegment, moRelease, moRelaxed
    )
    discard full.queue.segments.fetchAdd(1, moRelaxed)
    return (
      MPSCPushReady[T, S, MT, CC](
        MPSCPushContext[T, S, MT, CC](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      true,
    )
  else:
    # Lost race, caller should free newSegment
    # Try to advance using whatever segment won
    let winnerSeg = full.segment.next.load(moAcquire)
    if winnerSeg != nil:
      var expectedSeg = full.segment
      discard full.queue.tailSegment.compareExchange(
        expectedSeg, winnerSeg, moRelease, moRelaxed
      )
    return (
      MPSCPushReady[T, S, MT, CC](
        MPSCPushContext[T, S, MT, CC](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

# Write item to claimed slot
proc writeItem*[T; S, MT: static int, CC: static PinScopeCardinality](
    claimed: sink MPSCPushSlotClaimed[T, S, MT, CC], item: T
): MPSCPushItemWritten[T, S, MT, CC] {.transition.} =
  ## Write item to slot.
  claimed.segment.data[claimed.slot] = item

  MPSCPushItemWritten[T, S, MT, CC](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot,
  )

# Mark slot as committed
proc markCommitted*[T; S, MT: static int, CC: static PinScopeCardinality](
    written: sink MPSCPushItemWritten[T, S, MT, CC]
): MPSCPushComplete[T, S, MT, CC] {.transition.} =
  ## Mark slot as committed.
  written.segment.committed[written.slot].store(true, moRelease)
  discard written.queue.itemCount.fetchAdd(1, moRelaxed)

  MPSCPushComplete[T, S, MT, CC](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue,
  )
