## Typestate for unbounded MPSC pop operations.
##
## Bridges from DEBRA's Pinned[MT, CC] state, performs pop with committed flag check,
## bridges back. Single consumer checks committed flag before reading.

import ../atomic_dsl
import typestates
import debra

import ./unbounded_mpsc_push # Reuse MPSCSegment, UnboundedMupsicBase

type
  # Base context - carries pinned state and queue pointer
  # CC = ccSingle — single-consumer queue uses the no-race pin contract.
  MPSCPopContext*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]

  # States
  MPSCPopReady*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct MPSCPopContext[T, S, MT, CC]

  MPSCPopSegmentLoaded*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]
    head*: int
    tail*: int

  MPSCPopSlotAvailable*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]
    slot*: int

  MPSCPopSlotUncommitted*[
    T; S, MT: static int, CC: static PinScopeCardinality = ccSingle
  ] = object ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]

  MPSCPopSegmentExhausted*[
    T; S, MT: static int, CC: static PinScopeCardinality = ccSingle
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    segment*: ptr MPSCSegment[S, T]

  MPSCPopEmpty*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]

  MPSCPopComplete*[T; S, MT: static int, CC: static PinScopeCardinality = ccSingle] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT, CC]
    value*: T
    slot*: int

typestate MPSCPopContext[
  T, S: static int, MT: static int, CC: static PinScopeCardinality
]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  defaults:
    CC:
      ccSingle
  states MPSCPopReady[T, S, MT, CC],
    MPSCPopSegmentLoaded[T, S, MT, CC],
    MPSCPopSlotAvailable[T, S, MT, CC],
    MPSCPopSlotUncommitted[T, S, MT, CC],
    MPSCPopSegmentExhausted[T, S, MT, CC],
    MPSCPopEmpty[T, S, MT, CC],
    MPSCPopComplete[T, S, MT, CC]
  transitions:
    MPSCPopReady[T, S, MT, CC] -> MPSCPopSegmentLoaded[T, S, MT, CC]
    MPSCPopSegmentLoaded[T, S, MT, CC] ->
      (MPSCPopSlotAvailable[T, S, MT, CC] | MPSCPopSegmentExhausted[T, S, MT, CC]) as
      MPSCSlotCheck[T, S, MT, CC]
    MPSCPopSlotAvailable[T, S, MT, CC] ->
      (MPSCPopComplete[T, S, MT, CC] | MPSCPopSlotUncommitted[T, S, MT, CC]) as
      MPSCCommitCheck[T, S, MT, CC]
    MPSCPopSegmentExhausted[T, S, MT, CC] ->
      (MPSCPopReady[T, S, MT, CC] | MPSCPopEmpty[T, S, MT, CC]) as
      MPSCAdvanceResult[T, S, MT, CC]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int, CC: static PinScopeCardinality](
    pinned: sink Pinned[MT, CC], queue: ptr UnboundedMupsicBase[S, T, MT, CC]
): MPSCPopReady[T, S, MT, CC] =
  ## Create pop context from DEBRA's Pinned state.
  MPSCPopReady[T, S, MT, CC](
    MPSCPopContext[T, S, MT, CC](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: sink MPSCPopComplete[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: complete.pinnedHandle, epoch: complete.pinnedEpoch
    )
  )

proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    empty: sink MPSCPopEmpty[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    uncommitted: sink MPSCPopSlotUncommitted[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: uncommitted.pinnedHandle, epoch: uncommitted.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    ready: sink MPSCPopReady[T, S, MT, CC]
): MPSCPopSegmentLoaded[T, S, MT, CC] {.transition.} =
  ## Load current head segment and positions.
  let ctx = MPSCPopContext[T, S, MT, CC](ready)
  let seg = ctx.queue.headSegment
  let head = seg.head
  let tail = seg.tail.load(moAcquire)

  MPSCPopSegmentLoaded[T, S, MT, CC](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    head: head,
    tail: tail,
  )

# Check slot availability transition
proc checkSlot*[T; S, MT: static int, CC: static PinScopeCardinality](
    loaded: sink MPSCPopSegmentLoaded[T, S, MT, CC]
): MPSCSlotCheck[T, S, MT, CC] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    MPSCSlotCheck[T, S, MT, CC] ->
      MPSCPopSlotAvailable[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: loaded.head,
      )
  else:
    MPSCSlotCheck[T, S, MT, CC] ->
      MPSCPopSegmentExhausted[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

# Check if slot is committed and read item if ready
proc checkCommitted*[T; S, MT: static int, CC: static PinScopeCardinality](
    slotAvail: sink MPSCPopSlotAvailable[T, S, MT, CC]
): MPSCCommitCheck[T, S, MT, CC] {.transition.} =
  ## Check committed flag and read item if ready.
  if slotAvail.segment.committed[slotAvail.slot].load(moAcquire):
    # Slot is committed, read the item
    let value = slotAvail.segment.data[slotAvail.slot]

    # Advance head (single consumer, no atomic needed)
    slotAvail.segment.head = slotAvail.slot + 1
    discard slotAvail.queue.itemCount.fetchSub(1, moRelaxed)

    return
      MPSCCommitCheck[T, S, MT, CC] ->
      MPSCPopComplete[T, S, MT, CC](
        pinnedHandle: slotAvail.pinnedHandle,
        pinnedEpoch: slotAvail.pinnedEpoch,
        queue: slotAvail.queue,
        value: value,
        slot: slotAvail.slot,
      )
  else:
    # Producer hasn't finished writing yet
    return
      MPSCCommitCheck[T, S, MT, CC] ->
      MPSCPopSlotUncommitted[T, S, MT, CC](
        pinnedHandle: slotAvail.pinnedHandle,
        pinnedEpoch: slotAvail.pinnedEpoch,
        queue: slotAvail.queue,
      )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    exhausted: sink MPSCPopSegmentExhausted[T, S, MT, CC]
): MPSCAdvanceResult[T, S, MT, CC] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let nextSeg = exhausted.segment.next.load(moAcquire)

  if nextSeg == nil:
    return
      MPSCAdvanceResult[T, S, MT, CC] ->
      MPSCPopEmpty[T, S, MT, CC](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  # Advance head segment
  exhausted.queue.headSegment = nextSeg
  # Note: Segment retirement handled by caller

  MPSCAdvanceResult[T, S, MT, CC] ->
    MPSCPopReady[T, S, MT, CC](
      MPSCPopContext[T, S, MT, CC](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Get value from completed pop
proc getValue*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: MPSCPopComplete[T, S, MT, CC]
): T {.notATransition.} =
  ## Extract the popped value.
  complete.value
