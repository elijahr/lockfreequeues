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
    tail*: Atomic[int]  # CAS coordination for producers
    head*: int  # Consumer read position (single consumer, no atomic)
    committed*: array[S, Atomic[bool]]  # Track which slots are ready to read

  # Base queue type for MPSC
  UnboundedMupsicBase*[S: static int; T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr MPSCSegment[S, T]
    tailSegment*: Atomic[ptr MPSCSegment[S, T]]  # Atomic for CAS
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  # Note: T is NOT in the typestate generic params - only S and MT matter for state tracking
  MPSCPushContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer  # Generic pointer to avoid T in context

  # States
  MPSCPushReady*[S, MT: static int] = distinct MPSCPushContext[S, MT]

  MPSCPushSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer  # Generic ptr MPSCSegment
    tail*: int

  MPSCPushSegmentFull*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  MPSCPushSlotClaimed*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  MPSCPushItemWritten*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  MPSCPushComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer


typestate MPSCPushContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false  # Typed wrappers don't use {.transition.}
  states MPSCPushReady[S, MT], MPSCPushSegmentLoaded[S, MT],
         MPSCPushSegmentFull[S, MT], MPSCPushSlotClaimed[S, MT],
         MPSCPushItemWritten[S, MT], MPSCPushComplete[S, MT]
  transitions:
    MPSCPushReady[S, MT] -> MPSCPushSegmentLoaded[S, MT]
    MPSCPushSegmentLoaded[S, MT] -> (MPSCPushSlotClaimed[S, MT] | MPSCPushSegmentFull[S, MT] | MPSCPushReady[S, MT]) as MPSCSlotClaimResult[S, MT]
    MPSCPushSegmentFull[S, MT] -> MPSCPushReady[S, MT]
    MPSCPushSlotClaimed[S, MT] -> MPSCPushItemWritten[S, MT]
    MPSCPushItemWritten[S, MT] -> MPSCPushComplete[S, MT]


# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedMupsicBase[S, T, MT]
): MPSCPushReady[S, MT] =
  ## Create push context from DEBRA's Pinned state.
  MPSCPushReady[S, MT](
    MPSCPushContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


# Extract Pinned state from MPSCPushComplete for unpinning
proc extractPinned*[S, MT: static int](
  complete: sink MPSCPushComplete[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


# Load segment transition
proc loadSegment*[S, MT: static int](
  ready: sink MPSCPushReady[S, MT]
): MPSCPushSegmentLoaded[S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = MPSCPushContext[S, MT](ready)
  MPSCPushSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,  # Will be set by typed wrapper
    tail: 0)       # Will be set by typed wrapper


# Typed version that actually loads the segment
proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink MPSCPushReady[S, MT]
): MPSCPushSegmentLoaded[S, MT] =
  ## Load current tail segment and tail position (typed version).
  let ctx = MPSCPushContext[S, MT](ready)
  let queue = cast[ptr UnboundedMupsicBase[S, T, MT]](ctx.queue)
  let seg = queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  MPSCPushSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    tail: tail)


# Try to claim slot with CAS
proc tryClaimSlot*[S, MT: static int](
  loaded: sink MPSCPushSegmentLoaded[S, MT]
): MPSCSlotClaimResult[S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  if loaded.tail >= S:
    return MPSCSlotClaimResult[S, MT] -> MPSCPushSegmentFull[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # CAS logic done in typed version
  MPSCSlotClaimResult[S, MT] -> MPSCPushReady[S, MT](
    MPSCPushContext[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue))


# Typed version with actual CAS
proc tryClaimSlotTyped*[T; S, MT: static int](
  loaded: sink MPSCPushSegmentLoaded[S, MT]
): MPSCSlotClaimResult[S, MT] =
  ## Try to claim a slot using CAS (typed version).
  let seg = cast[ptr MPSCSegment[S, T]](loaded.segment)
  let tail = loaded.tail

  if tail >= S:
    return MPSCSlotClaimResult[S, MT] -> MPSCPushSegmentFull[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # Try CAS
  var expected = tail
  if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
    # Won the slot
    return MPSCSlotClaimResult[S, MT] -> MPSCPushSlotClaimed[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: tail)
  else:
    # CAS failed - retry from beginning
    return MPSCSlotClaimResult[S, MT] -> MPSCPushReady[S, MT](
      MPSCPushContext[S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue))


# Handle segment full - allocate new segment
proc allocateNewSegment*[S, MT: static int](
  full: sink MPSCPushSegmentFull[S, MT],
  newSegment: pointer
): MPSCPushReady[S, MT] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  ## Caller must allocate the segment before calling.
  MPSCPushReady[S, MT](
    MPSCPushContext[S, MT](
      pinnedHandle: full.pinnedHandle,
      pinnedEpoch: full.pinnedEpoch,
      queue: full.queue))


# Typed version that handles segment allocation with CAS
proc tryAllocateNewSegmentTyped*[T; S, MT: static int](
  full: sink MPSCPushSegmentFull[S, MT],
  newSegment: ptr MPSCSegment[S, T]
): tuple[ready: MPSCPushReady[S, MT], allocated: bool] =
  ## Try to link new segment using CAS (typed version).
  ## Returns (ready state, true if we allocated, false if someone else did).
  let queue = cast[ptr UnboundedMupsicBase[S, T, MT]](full.queue)
  let oldSeg = cast[ptr MPSCSegment[S, T]](full.segment)

  # Check if someone else already linked a segment
  let nextSeg = oldSeg.next.load(moAcquire)
  if nextSeg != nil:
    # Someone else allocated, just advance
    var expectedSeg = oldSeg
    discard queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
    return (MPSCPushReady[S, MT](
      MPSCPushContext[S, MT](
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue)), false)

  # Try to link our new segment
  var expectedNext: ptr MPSCSegment[S, T] = nil
  if oldSeg.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
    # Won the allocation race
    var expectedSeg = oldSeg
    discard queue.tailSegment.compareExchange(expectedSeg, newSegment, moRelease, moRelaxed)
    discard queue.segments.fetchAdd(1, moRelaxed)
    return (MPSCPushReady[S, MT](
      MPSCPushContext[S, MT](
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue)), true)
  else:
    # Lost race, caller should free newSegment
    # Try to advance using whatever segment won
    let winnerSeg = oldSeg.next.load(moAcquire)
    if winnerSeg != nil:
      var expectedSeg = oldSeg
      discard queue.tailSegment.compareExchange(expectedSeg, winnerSeg, moRelease, moRelaxed)
    return (MPSCPushReady[S, MT](
      MPSCPushContext[S, MT](
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue)), false)


# Write item to claimed slot
proc writeItem*[S, MT: static int](
  claimed: sink MPSCPushSlotClaimed[S, MT]
): MPSCPushItemWritten[S, MT] {.transition.} =
  ## Write item to slot. Actual write done by typed wrapper.
  MPSCPushItemWritten[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot)


# Typed version that actually writes the item
proc writeItemTyped*[T; S, MT: static int](
  claimed: sink MPSCPushSlotClaimed[S, MT],
  item: T
): MPSCPushItemWritten[S, MT] =
  ## Write item to slot (typed version).
  let seg = cast[ptr MPSCSegment[S, T]](claimed.segment)
  seg.data[claimed.slot] = item

  MPSCPushItemWritten[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot)


# Mark slot as committed
proc markCommitted*[S, MT: static int](
  written: sink MPSCPushItemWritten[S, MT]
): MPSCPushComplete[S, MT] {.transition.} =
  ## Mark slot as committed. Actual commit done by typed wrapper.
  MPSCPushComplete[S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue)


# Typed version that actually commits
proc markCommittedTyped*[T; S, MT: static int](
  written: sink MPSCPushItemWritten[S, MT]
): MPSCPushComplete[S, MT] =
  ## Mark slot as committed (typed version).
  let queue = cast[ptr UnboundedMupsicBase[S, T, MT]](written.queue)
  let seg = cast[ptr MPSCSegment[S, T]](written.segment)
  seg.committed[written.slot].store(true, moRelease)
  discard queue.itemCount.fetchAdd(1, moRelaxed)

  MPSCPushComplete[S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue)
