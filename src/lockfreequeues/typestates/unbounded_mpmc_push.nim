## Typestate for unbounded MPMC push operations.
##
## Bridges from DEBRA's Pinned[MT, CC] state, performs push with CAS coordination
## and committed flags, bridges back. Multiple producers coordinate via CAS on tail.

import ../atomic_dsl
import typestates
import debra

type
  # Segment type for MPMC - has committed flags and prevConsumerIdx
  MPMCSegment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr MPMCSegment[S, T]]
    tail*: Atomic[int] # CAS coordination for producers
    prevConsumerIdx*: Atomic[int] # CAS coordination for consumers
    committed*: array[S, Atomic[bool]] # Track which slots are ready to read

  # Base queue type for MPMC
  # CC = ccMulti — consumer side is multi-consumer (mpmc_pop coordinates via
  # CAS), so the nim-debra pin/retire contract requires the manager/handle
  # axis to be ccMulti.
  UnboundedMupmucBase*[
    S: static int, T; MaxThreads: static int, CC: static PinScopeCardinality = ccMulti
  ] = object
    manager*: ptr DebraManager[MaxThreads, CC]
    headSegment*: ptr MPMCSegment[S, T]
    tailSegment*: Atomic[ptr MPMCSegment[S, T]] # Atomic for CAS
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  MPMCPushContext*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object of RootObj
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]

  # States
  MPMCPushReady*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] =
    distinct MPMCPushContext[T, S, MT, CC]

  MPMCPushSegmentLoaded*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]
    tail*: int

  MPMCPushSegmentFull*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]

  MPMCPushSlotClaimed*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]
    slot*: int

  MPMCPushItemWritten*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]
    slot*: int

  MPMCPushComplete*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]

typestate MPMCPushContext[
  T, S: static int, MT: static int, CC: static PinScopeCardinality
]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  defaults:
    CC:
      ccMulti
  states MPMCPushReady[T, S, MT, CC],
    MPMCPushSegmentLoaded[T, S, MT, CC],
    MPMCPushSegmentFull[T, S, MT, CC],
    MPMCPushSlotClaimed[T, S, MT, CC],
    MPMCPushItemWritten[T, S, MT, CC],
    MPMCPushComplete[T, S, MT, CC]
  transitions:
    MPMCPushReady[T, S, MT, CC] -> MPMCPushSegmentLoaded[T, S, MT, CC]
    MPMCPushSegmentLoaded[T, S, MT, CC] ->
      (
        MPMCPushSlotClaimed[T, S, MT, CC] | MPMCPushSegmentFull[T, S, MT, CC] |
        MPMCPushReady[T, S, MT, CC]
      ) as MPMCSlotClaimResult[T, S, MT, CC]
    MPMCPushSegmentFull[T, S, MT, CC] -> MPMCPushReady[T, S, MT, CC]
    MPMCPushSlotClaimed[T, S, MT, CC] -> MPMCPushItemWritten[T, S, MT, CC]
    MPMCPushItemWritten[T, S, MT, CC] -> MPMCPushComplete[T, S, MT, CC]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int, CC: static PinScopeCardinality](
    pinned: sink Pinned[MT, CC], queue: ptr UnboundedMupmucBase[S, T, MT, CC]
): MPMCPushReady[T, S, MT, CC] =
  ## Create push context from DEBRA's Pinned state.
  MPMCPushReady[T, S, MT, CC](
    MPMCPushContext[T, S, MT, CC](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from MPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: sink MPMCPushComplete[T, S, MT, CC]
): Pinned[MT, CC] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: complete.pinnedHandle, epoch: complete.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    ready: sink MPMCPushReady[T, S, MT, CC]
): MPMCPushSegmentLoaded[T, S, MT, CC] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = MPMCPushContext[T, S, MT, CC](ready)
  let seg = ctx.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  MPMCPushSegmentLoaded[T, S, MT, CC](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int, CC: static PinScopeCardinality](
    loaded: sink MPMCPushSegmentLoaded[T, S, MT, CC]
): MPMCSlotClaimResult[T, S, MT, CC] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  let tail = loaded.tail

  if tail >= S:
    return
      MPMCSlotClaimResult[T, S, MT, CC] ->
      MPMCPushSegmentFull[T, S, MT, CC](
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
      MPMCSlotClaimResult[T, S, MT, CC] ->
      MPMCPushSlotClaimed[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: tail,
      )
  else:
    # CAS failed - retry from beginning
    return
      MPMCSlotClaimResult[T, S, MT, CC] ->
      MPMCPushReady[T, S, MT, CC](
        MPMCPushContext[T, S, MT, CC](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Handle segment full - allocate new segment
proc allocateNewSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    full: sink MPMCPushSegmentFull[T, S, MT, CC], newSegment: ptr MPMCSegment[S, T]
): MPMCPushReady[T, S, MT, CC] {.transition.} =
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
    var expectedNext: ptr MPMCSegment[S, T] = nil
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

  MPMCPushReady[T, S, MT, CC](
    MPMCPushContext[T, S, MT, CC](
      pinnedHandle: full.pinnedHandle, pinnedEpoch: full.pinnedEpoch, queue: full.queue
    )
  )

# Helper that returns allocation status (for callers who need to know if they should free newSegment)
proc tryAllocateNewSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    full: sink MPMCPushSegmentFull[T, S, MT, CC], newSegment: ptr MPMCSegment[S, T]
): tuple[ready: MPMCPushReady[T, S, MT, CC], allocated: bool] =
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
      MPMCPushReady[T, S, MT, CC](
        MPMCPushContext[T, S, MT, CC](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

  # Try to link our new segment
  var expectedNext: ptr MPMCSegment[S, T] = nil
  if full.segment.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
    # Won the allocation race
    var expectedSeg = full.segment
    discard full.queue.tailSegment.compareExchange(
      expectedSeg, newSegment, moRelease, moRelaxed
    )
    discard full.queue.segments.fetchAdd(1, moRelaxed)
    return (
      MPMCPushReady[T, S, MT, CC](
        MPMCPushContext[T, S, MT, CC](
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
      MPMCPushReady[T, S, MT, CC](
        MPMCPushContext[T, S, MT, CC](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

# Write item to claimed slot
proc writeItem*[T; S, MT: static int, CC: static PinScopeCardinality](
    claimed: sink MPMCPushSlotClaimed[T, S, MT, CC], item: T
): MPMCPushItemWritten[T, S, MT, CC] {.transition.} =
  ## Write item to slot.
  claimed.segment.data[claimed.slot] = item

  MPMCPushItemWritten[T, S, MT, CC](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot,
  )

# Mark slot as committed
proc markCommitted*[T; S, MT: static int, CC: static PinScopeCardinality](
    written: sink MPMCPushItemWritten[T, S, MT, CC]
): MPMCPushComplete[T, S, MT, CC] {.transition.} =
  ## Mark slot as committed.
  written.segment.committed[written.slot].store(true, moRelease)
  discard written.queue.itemCount.fetchAdd(1, moRelaxed)

  MPMCPushComplete[T, S, MT, CC](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue,
  )
