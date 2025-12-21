## Typestate for unbounded MPSC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push with CAS coordination,
## bridges back. Multiple producers coordinate via CAS on tail pointer.

import atomics
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
  UnboundedMupsicBase*[S: static int, T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr MPSCSegment[S, T]
    tailSegment*: Atomic[ptr MPSCSegment[S, T]] # Atomic for CAS
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  MPSCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  # States
  MPSCPushReady*[T; S, MT: static int] = distinct MPSCPushContext[T, S, MT]

  MPSCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]
    tail*: int

  MPSCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]

  MPSCPushSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]
    slot*: int

  MPSCPushItemWritten*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]
    slot*: int

  MPSCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

typestate MPSCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states MPSCPushReady[T, S, MT],
    MPSCPushSegmentLoaded[T, S, MT],
    MPSCPushSegmentFull[T, S, MT],
    MPSCPushSlotClaimed[T, S, MT],
    MPSCPushItemWritten[T, S, MT],
    MPSCPushComplete[T, S, MT]
  transitions:
    MPSCPushReady[T, S, MT] -> MPSCPushSegmentLoaded[T, S, MT]
    MPSCPushSegmentLoaded[T, S, MT] ->
      (
        MPSCPushSlotClaimed[T, S, MT] | MPSCPushSegmentFull[T, S, MT] |
        MPSCPushReady[T, S, MT]
      ) as MPSCSlotClaimResult[T, S, MT]
    MPSCPushSegmentFull[T, S, MT] -> MPSCPushReady[T, S, MT]
    MPSCPushSlotClaimed[T, S, MT] -> MPSCPushItemWritten[T, S, MT]
    MPSCPushItemWritten[T, S, MT] -> MPSCPushComplete[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupsicBase[S, T, MT]
): MPSCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  MPSCPushReady[T, S, MT](
    MPSCPushContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from MPSCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink MPSCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink MPSCPushReady[T, S, MT]
): MPSCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = MPSCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  MPSCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink MPSCPushSegmentLoaded[T, S, MT]
): MPSCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  let tail = loaded.tail

  if tail >= S:
    return
      MPSCSlotClaimResult[T, S, MT] ->
      MPSCPushSegmentFull[T, S, MT](
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
      MPSCSlotClaimResult[T, S, MT] ->
      MPSCPushSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: tail,
      )
  else:
    # CAS failed - retry from beginning
    return
      MPSCSlotClaimResult[T, S, MT] ->
      MPSCPushReady[T, S, MT](
        MPSCPushContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Handle segment full - allocate new segment
proc allocateNewSegment*[T; S, MT: static int](
    full: sink MPSCPushSegmentFull[T, S, MT], newSegment: ptr MPSCSegment[S, T]
): MPSCPushReady[T, S, MT] {.transition.} =
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

  MPSCPushReady[T, S, MT](
    MPSCPushContext[T, S, MT](
      pinnedHandle: full.pinnedHandle, pinnedEpoch: full.pinnedEpoch, queue: full.queue
    )
  )

# Helper that returns allocation status (for callers who need to know if they should free newSegment)
proc tryAllocateNewSegment*[T; S, MT: static int](
    full: sink MPSCPushSegmentFull[T, S, MT], newSegment: ptr MPSCSegment[S, T]
): tuple[ready: MPSCPushReady[T, S, MT], allocated: bool] =
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
      MPSCPushReady[T, S, MT](
        MPSCPushContext[T, S, MT](
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
      MPSCPushReady[T, S, MT](
        MPSCPushContext[T, S, MT](
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
      MPSCPushReady[T, S, MT](
        MPSCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

# Write item to claimed slot
proc writeItem*[T; S, MT: static int](
    claimed: sink MPSCPushSlotClaimed[T, S, MT], item: T
): MPSCPushItemWritten[T, S, MT] {.transition.} =
  ## Write item to slot.
  claimed.segment.data[claimed.slot] = item

  MPSCPushItemWritten[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot,
  )

# Mark slot as committed
proc markCommitted*[T; S, MT: static int](
    written: sink MPSCPushItemWritten[T, S, MT]
): MPSCPushComplete[T, S, MT] {.transition.} =
  ## Mark slot as committed.
  written.segment.committed[written.slot].store(true, moRelease)
  discard written.queue.itemCount.fetchAdd(1, moRelaxed)

  MPSCPushComplete[T, S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue,
  )
