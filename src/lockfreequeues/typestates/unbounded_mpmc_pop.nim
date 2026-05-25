## Typestate for unbounded MPMC pop operations.
##
## Bridges from DEBRA's Pinned[MT, CC] state, performs pop with CAS coordination
## and committed flag check, bridges back. Multiple consumers coordinate via
## CAS on prevConsumerIdx, and must check committed flag before reading.

import ../atomic_dsl
import typestates
import debra

import ./unbounded_mpmc_push # Reuse MPMCSegment, UnboundedMupmucBase

type
  # Base context - carries pinned state and queue pointer
  # CC = ccMulti — multi-consumer pop coordinates via CAS, so the nim-debra
  # pin contract requires the manager/handle axis to be ccMulti.
  MPMCPopContext*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object of RootObj
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]

  # States
  MPMCPopReady*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] =
    distinct MPMCPopContext[T, S, MT, CC]

  MPMCPopSegmentLoaded*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]
    tail*: int
    prevConsumerIdx*: int

  MPMCPopSlotClaimed*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]
    slot*: int

  MPMCPopSlotUncommitted*[
    T; S, MT: static int, CC: static PinScopeCardinality = ccMulti
  ] = object ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]

  MPMCPopSegmentExhausted*[
    T; S, MT: static int, CC: static PinScopeCardinality = ccMulti
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    segment*: ptr MPMCSegment[S, T]

  MPMCPopEmpty*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]

  MPMCPopComplete*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT, CC]
    value*: T
    slot*: int
    isLastSlot*: bool

typestate MPMCPopContext[
  T, S: static int, MT: static int, CC: static PinScopeCardinality
]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  defaults:
    CC:
      ccMulti
  states MPMCPopReady[T, S, MT, CC],
    MPMCPopSegmentLoaded[T, S, MT, CC],
    MPMCPopSlotClaimed[T, S, MT, CC],
    MPMCPopSlotUncommitted[T, S, MT, CC],
    MPMCPopSegmentExhausted[T, S, MT, CC],
    MPMCPopEmpty[T, S, MT, CC],
    MPMCPopComplete[T, S, MT, CC]
  transitions:
    MPMCPopReady[T, S, MT, CC] -> MPMCPopSegmentLoaded[T, S, MT, CC]
    MPMCPopSegmentLoaded[T, S, MT, CC] ->
      (
        MPMCPopSlotClaimed[T, S, MT, CC] | MPMCPopSegmentExhausted[T, S, MT, CC] |
        MPMCPopSlotUncommitted[T, S, MT, CC] | MPMCPopReady[T, S, MT, CC]
      ) as MPMCPopSlotClaimResult[T, S, MT, CC]
    MPMCPopSlotClaimed[T, S, MT, CC] ->
      (MPMCPopComplete[T, S, MT, CC] | MPMCPopSlotUncommitted[T, S, MT, CC]) as
      MPMCPopCommitCheck[T, S, MT, CC]
    MPMCPopSegmentExhausted[T, S, MT, CC] ->
      (MPMCPopReady[T, S, MT, CC] | MPMCPopEmpty[T, S, MT, CC]) as
      MPMCPopAdvanceResult[T, S, MT, CC]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int, CC: static PinScopeCardinality](
    pinned: sink Pinned[MT, CC], queue: ptr UnboundedMupmucBase[S, T, MT, CC]
): MPMCPopReady[T, S, MT, CC] =
  ## Create pop context from DEBRA's Pinned state.
  MPMCPopReady[T, S, MT, CC](
    MPMCPopContext[T, S, MT, CC](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: sink MPMCPopComplete[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: complete.pinnedHandle, epoch: complete.pinnedEpoch
    )
  )

proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    empty: sink MPMCPopEmpty[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    uncommitted: sink MPMCPopSlotUncommitted[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: uncommitted.pinnedHandle, epoch: uncommitted.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    ready: sink MPMCPopReady[T, S, MT, CC]
): MPMCPopSegmentLoaded[T, S, MT, CC] {.transition.} =
  ## Load current head segment and positions.
  let ctx = MPMCPopContext[T, S, MT, CC](ready)
  let seg = ctx.queue.headSegment
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.prevConsumerIdx.load(moAcquire)

  MPMCPopSegmentLoaded[T, S, MT, CC](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    prevConsumerIdx: prevIdx,
  )

# Check committed flag before CAS attempt
proc tryClaimSlot*[T; S, MT: static int, CC: static PinScopeCardinality](
    loaded: sink MPMCPopSegmentLoaded[T, S, MT, CC]
): MPMCPopSlotClaimResult[T, S, MT, CC] {.transition.} =
  ## Try to claim a slot with CAS coordination.
  ## Returns SlotClaimed, SegmentExhausted, SlotUncommitted, or Ready for retry.
  let seg = loaded.segment
  let mySlot = loaded.prevConsumerIdx + 1

  if mySlot >= loaded.tail:
    return
      MPMCPopSlotClaimResult[T, S, MT, CC] ->
      MPMCPopSegmentExhausted[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Check if slot is committed before trying to claim
  if not seg.committed[mySlot].load(moAcquire):
    return
      MPMCPopSlotClaimResult[T, S, MT, CC] ->
      MPMCPopSlotUncommitted[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
      )

  # CAS to claim slot
  var expected = loaded.prevConsumerIdx
  if seg.prevConsumerIdx.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    return
      MPMCPopSlotClaimResult[T, S, MT, CC] ->
      MPMCPopSlotClaimed[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: mySlot,
      )
  else:
    # CAS failed - retry
    return
      MPMCPopSlotClaimResult[T, S, MT, CC] ->
      MPMCPopReady[T, S, MT, CC](
        MPMCPopContext[T, S, MT, CC](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Read item from claimed slot
proc readItem*[T; S, MT: static int, CC: static PinScopeCardinality](
    claimed: sink MPMCPopSlotClaimed[T, S, MT, CC]
): MPMCPopCommitCheck[T, S, MT, CC] {.transition.} =
  ## Check committed flag and read item if ready.
  let queue = claimed.queue
  let seg = claimed.segment

  # Double-check committed (should be true if we got here via tryClaimSlot)
  if not seg.committed[claimed.slot].load(moAcquire):
    return
      MPMCPopCommitCheck[T, S, MT, CC] ->
      MPMCPopSlotUncommitted[T, S, MT, CC](
        pinnedHandle: claimed.pinnedHandle,
        pinnedEpoch: claimed.pinnedEpoch,
        queue: claimed.queue,
      )

  let value = seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  MPMCPopCommitCheck[T, S, MT, CC] ->
    MPMCPopComplete[T, S, MT, CC](
      pinnedHandle: claimed.pinnedHandle,
      pinnedEpoch: claimed.pinnedEpoch,
      queue: claimed.queue,
      value: value,
      slot: claimed.slot,
      isLastSlot: claimed.slot == S - 1,
    )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    exhausted: sink MPMCPopSegmentExhausted[T, S, MT, CC]
): MPMCPopAdvanceResult[T, S, MT, CC] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return
      MPMCPopAdvanceResult[T, S, MT, CC] ->
      MPMCPopEmpty[T, S, MT, CC](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  MPMCPopAdvanceResult[T, S, MT, CC] ->
    MPMCPopReady[T, S, MT, CC](
      MPMCPopContext[T, S, MT, CC](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Get value from completed pop
proc getValue*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: MPMCPopComplete[T, S, MT, CC]
): T {.notATransition.} =
  ## Extract the popped value.
  complete.value
