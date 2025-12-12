## Typestate for unbounded MPSC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with committed flag check,
## bridges back. Single consumer checks committed flag before reading.

import atomics
import typestates
import debra

import ./unbounded_mpsc_push  # Reuse MPSCSegment, UnboundedMupsicBase

type
  # Base context - carries pinned state and queue pointer
  # Note: T is NOT in the typestate generic params - only S and MT matter for state tracking
  MPSCPopContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer  # Generic pointer to avoid T in context

  # States
  MPSCPopReady*[S, MT: static int] = distinct MPSCPopContext[S, MT]

  MPSCPopSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer  # Generic ptr MPSCSegment
    head*: int
    tail*: int

  MPSCPopSlotAvailable*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  MPSCPopSlotUncommitted*[S, MT: static int] = object
    ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  MPSCPopSegmentExhausted*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  MPSCPopEmpty*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  MPSCPopComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    valuePtr*: pointer  # Generic pointer to value (caller extracts with type)
    slot*: int


typestate MPSCPopContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false  # Typed wrappers don't use {.transition.}
  states MPSCPopReady[S, MT], MPSCPopSegmentLoaded[S, MT],
         MPSCPopSlotAvailable[S, MT], MPSCPopSlotUncommitted[S, MT],
         MPSCPopSegmentExhausted[S, MT], MPSCPopEmpty[S, MT],
         MPSCPopComplete[S, MT]
  transitions:
    MPSCPopReady[S, MT] -> MPSCPopSegmentLoaded[S, MT]
    MPSCPopSegmentLoaded[S, MT] -> (MPSCPopSlotAvailable[S, MT] | MPSCPopSegmentExhausted[S, MT]) as MPSCSlotCheck[S, MT]
    MPSCPopSlotAvailable[S, MT] -> (MPSCPopComplete[S, MT] | MPSCPopSlotUncommitted[S, MT]) as MPSCCommitCheck[S, MT]
    MPSCPopSegmentExhausted[S, MT] -> (MPSCPopReady[S, MT] | MPSCPopEmpty[S, MT]) as MPSCAdvanceResult[S, MT]


# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedMupsicBase[S, T, MT]
): MPSCPopReady[S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  MPSCPopReady[S, MT](
    MPSCPopContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


# Extract Pinned state from terminal states
proc extractPinned*[S, MT: static int](
  complete: sink MPSCPopComplete[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))

proc extractPinned*[S, MT: static int](
  empty: sink MPSCPopEmpty[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: empty.pinnedHandle,
    epoch: empty.pinnedEpoch))

proc extractPinned*[S, MT: static int](
  uncommitted: sink MPSCPopSlotUncommitted[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: uncommitted.pinnedHandle,
    epoch: uncommitted.pinnedEpoch))


# Load segment transition
proc loadSegment*[S, MT: static int](
  ready: sink MPSCPopReady[S, MT]
): MPSCPopSegmentLoaded[S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = MPSCPopContext[S, MT](ready)
  MPSCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,  # Will be set by typed wrapper
    head: 0,       # Will be set by typed wrapper
    tail: 0)       # Will be set by typed wrapper


# Typed version that actually loads the segment
proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink MPSCPopReady[S, MT]
): MPSCPopSegmentLoaded[S, MT] =
  ## Load current head segment and positions (typed version).
  let ctx = MPSCPopContext[S, MT](ready)
  let queue = cast[ptr UnboundedMupsicBase[S, T, MT]](ctx.queue)
  let seg = queue.headSegment
  let head = seg.head
  let tail = seg.tail.load(moAcquire)

  MPSCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    head: head,
    tail: tail)


# Check slot availability transition
proc checkSlot*[S, MT: static int](
  loaded: sink MPSCPopSegmentLoaded[S, MT]
): MPSCSlotCheck[S, MT] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    MPSCSlotCheck[S, MT] -> MPSCPopSlotAvailable[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.head)
  else:
    MPSCSlotCheck[S, MT] -> MPSCPopSegmentExhausted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)


# Check if slot is committed
proc checkCommitted*[S, MT: static int](
  slotAvail: sink MPSCPopSlotAvailable[S, MT]
): MPSCCommitCheck[S, MT] {.transition.} =
  ## Check committed flag. Actual check done by typed wrapper.
  MPSCCommitCheck[S, MT] -> MPSCPopSlotUncommitted[S, MT](
    pinnedHandle: slotAvail.pinnedHandle,
    pinnedEpoch: slotAvail.pinnedEpoch,
    queue: slotAvail.queue)


# Typed version that checks committed flag and reads item if ready
proc checkCommittedAndReadTyped*[T; S, MT: static int](
  slotAvail: sink MPSCPopSlotAvailable[S, MT]
): MPSCCommitCheck[S, MT] =
  ## Check committed flag and read item if ready (typed version).
  let queue = cast[ptr UnboundedMupsicBase[S, T, MT]](slotAvail.queue)
  let seg = cast[ptr MPSCSegment[S, T]](slotAvail.segment)

  if seg.committed[slotAvail.slot].load(moAcquire):
    # Slot is committed, read the item
    let valuePtr = addr seg.data[slotAvail.slot]

    # Advance head (single consumer, no atomic needed)
    seg.head = slotAvail.slot + 1
    discard queue.itemCount.fetchSub(1, moRelaxed)

    return MPSCCommitCheck[S, MT] -> MPSCPopComplete[S, MT](
      pinnedHandle: slotAvail.pinnedHandle,
      pinnedEpoch: slotAvail.pinnedEpoch,
      queue: slotAvail.queue,
      valuePtr: cast[pointer](valuePtr),
      slot: slotAvail.slot)
  else:
    # Producer hasn't finished writing yet
    return MPSCCommitCheck[S, MT] -> MPSCPopSlotUncommitted[S, MT](
      pinnedHandle: slotAvail.pinnedHandle,
      pinnedEpoch: slotAvail.pinnedEpoch,
      queue: slotAvail.queue)


# Advance segment transition
proc advanceSegment*[S, MT: static int](
  exhausted: sink MPSCPopSegmentExhausted[S, MT]
): MPSCAdvanceResult[S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Note: Actual segment advancement done by typed wrapper.
  MPSCAdvanceResult[S, MT] -> MPSCPopEmpty[S, MT](
    pinnedHandle: exhausted.pinnedHandle,
    pinnedEpoch: exhausted.pinnedEpoch,
    queue: exhausted.queue)


# Typed version that actually advances the segment
proc advanceSegmentTyped*[T; S, MT: static int](
  exhausted: sink MPSCPopSegmentExhausted[S, MT]
): MPSCAdvanceResult[S, MT] =
  ## Try to advance to next segment (typed version).
  let queue = cast[ptr UnboundedMupsicBase[S, T, MT]](exhausted.queue)
  let seg = cast[ptr MPSCSegment[S, T]](exhausted.segment)
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return MPSCAdvanceResult[S, MT] -> MPSCPopEmpty[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue)

  # Advance head segment
  queue.headSegment = nextSeg
  # Note: Segment retirement handled by caller

  MPSCAdvanceResult[S, MT] -> MPSCPopReady[S, MT](
    MPSCPopContext[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue))


# Get value from completed pop
proc getValue*[T; S, MT: static int](
  complete: MPSCPopComplete[S, MT]
): T =
  ## Extract the popped value.
  cast[ptr T](complete.valuePtr)[]
