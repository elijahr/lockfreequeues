## Typestate for unbounded MPMC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push with CAS coordination
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
  UnboundedMupmucBase*[S: static int, T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr MPMCSegment[S, T]
    tailSegment*: Atomic[ptr MPMCSegment[S, T]] # Atomic for CAS
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  MPMCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  # States
  MPMCPushReady*[T; S, MT: static int] = distinct MPMCPushContext[T, S, MT]

  MPMCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]
    tail*: int

  MPMCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]

  MPMCPushSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]
    slot*: int

  MPMCPushItemWritten*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]
    slot*: int

  MPMCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

typestate MPMCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states MPMCPushReady[T, S, MT],
    MPMCPushSegmentLoaded[T, S, MT],
    MPMCPushSegmentFull[T, S, MT],
    MPMCPushSlotClaimed[T, S, MT],
    MPMCPushItemWritten[T, S, MT],
    MPMCPushComplete[T, S, MT]
  transitions:
    MPMCPushReady[T, S, MT] -> MPMCPushSegmentLoaded[T, S, MT]
    MPMCPushSegmentLoaded[T, S, MT] ->
      (
        MPMCPushSlotClaimed[T, S, MT] | MPMCPushSegmentFull[T, S, MT] |
        MPMCPushReady[T, S, MT]
      ) as MPMCSlotClaimResult[T, S, MT]
    MPMCPushSegmentFull[T, S, MT] -> MPMCPushReady[T, S, MT]
    MPMCPushSlotClaimed[T, S, MT] -> MPMCPushItemWritten[T, S, MT]
    MPMCPushItemWritten[T, S, MT] -> MPMCPushComplete[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupmucBase[S, T, MT]
): MPMCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  MPMCPushReady[T, S, MT](
    MPMCPushContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from MPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink MPMCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink MPMCPushReady[T, S, MT]
): MPMCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = MPMCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  MPMCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink MPMCPushSegmentLoaded[T, S, MT]
): MPMCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  let tail = loaded.tail

  if tail >= S:
    return
      MPMCSlotClaimResult[T, S, MT] ->
      MPMCPushSegmentFull[T, S, MT](
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
      MPMCSlotClaimResult[T, S, MT] ->
      MPMCPushSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: tail,
      )
  else:
    # CAS failed - retry from beginning
    return
      MPMCSlotClaimResult[T, S, MT] ->
      MPMCPushReady[T, S, MT](
        MPMCPushContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Handle segment full - allocate new segment
proc allocateNewSegment*[T; S, MT: static int](
    full: sink MPMCPushSegmentFull[T, S, MT], newSegment: ptr MPMCSegment[S, T]
): MPMCPushReady[T, S, MT] {.transition.} =
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

  MPMCPushReady[T, S, MT](
    MPMCPushContext[T, S, MT](
      pinnedHandle: full.pinnedHandle, pinnedEpoch: full.pinnedEpoch, queue: full.queue
    )
  )

# Helper that returns allocation status (for callers who need to know if they should free newSegment)
proc tryAllocateNewSegment*[T; S, MT: static int](
    full: sink MPMCPushSegmentFull[T, S, MT], newSegment: ptr MPMCSegment[S, T]
): tuple[ready: MPMCPushReady[T, S, MT], allocated: bool] =
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
      MPMCPushReady[T, S, MT](
        MPMCPushContext[T, S, MT](
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
      MPMCPushReady[T, S, MT](
        MPMCPushContext[T, S, MT](
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
      MPMCPushReady[T, S, MT](
        MPMCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

# Write item to claimed slot
proc writeItem*[T; S, MT: static int](
    claimed: sink MPMCPushSlotClaimed[T, S, MT], item: T
): MPMCPushItemWritten[T, S, MT] {.transition.} =
  ## Write item to slot.
  claimed.segment.data[claimed.slot] = item

  MPMCPushItemWritten[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot,
  )

# Mark slot as committed
proc markCommitted*[T; S, MT: static int](
    written: sink MPMCPushItemWritten[T, S, MT]
): MPMCPushComplete[T, S, MT] {.transition.} =
  ## Mark slot as committed.
  written.segment.committed[written.slot].store(true, moRelease)
  discard written.queue.itemCount.fetchAdd(1, moRelaxed)

  MPMCPushComplete[T, S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue,
  )
