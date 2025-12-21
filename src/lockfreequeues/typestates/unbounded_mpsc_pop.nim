## Typestate for unbounded MPSC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with committed flag check,
## bridges back. Single consumer checks committed flag before reading.

import atomics
import typestates
import debra

import ./unbounded_mpsc_push # Reuse MPSCSegment, UnboundedMupsicBase

type
  # Base context - carries pinned state and queue pointer
  MPSCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  # States
  MPSCPopReady*[T; S, MT: static int] = distinct MPSCPopContext[T, S, MT]

  MPSCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]
    head*: int
    tail*: int

  MPSCPopSlotAvailable*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]
    slot*: int

  MPSCPopSlotUncommitted*[T; S, MT: static int] = object
    ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  MPSCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr MPSCSegment[S, T]

  MPSCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  MPSCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    value*: T
    slot*: int

typestate MPSCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states MPSCPopReady[T, S, MT],
    MPSCPopSegmentLoaded[T, S, MT],
    MPSCPopSlotAvailable[T, S, MT],
    MPSCPopSlotUncommitted[T, S, MT],
    MPSCPopSegmentExhausted[T, S, MT],
    MPSCPopEmpty[T, S, MT],
    MPSCPopComplete[T, S, MT]
  transitions:
    MPSCPopReady[T, S, MT] -> MPSCPopSegmentLoaded[T, S, MT]
    MPSCPopSegmentLoaded[T, S, MT] ->
      (MPSCPopSlotAvailable[T, S, MT] | MPSCPopSegmentExhausted[T, S, MT]) as
      MPSCSlotCheck[T, S, MT]
    MPSCPopSlotAvailable[T, S, MT] ->
      (MPSCPopComplete[T, S, MT] | MPSCPopSlotUncommitted[T, S, MT]) as
      MPSCCommitCheck[T, S, MT]
    MPSCPopSegmentExhausted[T, S, MT] ->
      (MPSCPopReady[T, S, MT] | MPSCPopEmpty[T, S, MT]) as MPSCAdvanceResult[T, S, MT]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupsicBase[S, T, MT]
): MPSCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  MPSCPopReady[T, S, MT](
    MPSCPopContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
    complete: sink MPSCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    empty: sink MPSCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    uncommitted: sink MPSCPopSlotUncommitted[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](
      handle: uncommitted.pinnedHandle, epoch: uncommitted.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink MPSCPopReady[T, S, MT]
): MPSCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = MPSCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment
  let head = seg.head
  let tail = seg.tail.load(moAcquire)

  MPSCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    head: head,
    tail: tail,
  )

# Check slot availability transition
proc checkSlot*[T; S, MT: static int](
    loaded: sink MPSCPopSegmentLoaded[T, S, MT]
): MPSCSlotCheck[T, S, MT] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    MPSCSlotCheck[T, S, MT] ->
      MPSCPopSlotAvailable[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: loaded.head,
      )
  else:
    MPSCSlotCheck[T, S, MT] ->
      MPSCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

# Check if slot is committed and read item if ready
proc checkCommitted*[T; S, MT: static int](
    slotAvail: sink MPSCPopSlotAvailable[T, S, MT]
): MPSCCommitCheck[T, S, MT] {.transition.} =
  ## Check committed flag and read item if ready.
  if slotAvail.segment.committed[slotAvail.slot].load(moAcquire):
    # Slot is committed, read the item
    let value = slotAvail.segment.data[slotAvail.slot]

    # Advance head (single consumer, no atomic needed)
    slotAvail.segment.head = slotAvail.slot + 1
    discard slotAvail.queue.itemCount.fetchSub(1, moRelaxed)

    return
      MPSCCommitCheck[T, S, MT] ->
      MPSCPopComplete[T, S, MT](
        pinnedHandle: slotAvail.pinnedHandle,
        pinnedEpoch: slotAvail.pinnedEpoch,
        queue: slotAvail.queue,
        value: value,
        slot: slotAvail.slot,
      )
  else:
    # Producer hasn't finished writing yet
    return
      MPSCCommitCheck[T, S, MT] ->
      MPSCPopSlotUncommitted[T, S, MT](
        pinnedHandle: slotAvail.pinnedHandle,
        pinnedEpoch: slotAvail.pinnedEpoch,
        queue: slotAvail.queue,
      )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
    exhausted: sink MPSCPopSegmentExhausted[T, S, MT]
): MPSCAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let nextSeg = exhausted.segment.next.load(moAcquire)

  if nextSeg == nil:
    return
      MPSCAdvanceResult[T, S, MT] ->
      MPSCPopEmpty[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  # Advance head segment
  exhausted.queue.headSegment = nextSeg
  # Note: Segment retirement handled by caller

  MPSCAdvanceResult[T, S, MT] ->
    MPSCPopReady[T, S, MT](
      MPSCPopContext[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Get value from completed pop
proc getValue*[T; S, MT: static int](complete: MPSCPopComplete[T, S, MT]): T =
  ## Extract the popped value.
  complete.value
