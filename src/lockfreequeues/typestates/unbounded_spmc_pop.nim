## Typestate for unbounded SPMC pop operations.
##
## Bridges from DEBRA's Pinned[MT, CC] state, performs pop with CAS coordination,
## bridges back. Multiple consumers coordinate via CAS on prevConsumerIdx.

import ../atomic_dsl
import typestates
import debra

type
  # Segment type for SPMC - has prevConsumerIdx for CAS
  SPMCSegment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr SPMCSegment[S, T]]
    tail*: Atomic[int] # Producer write position
    prevConsumerIdx*: Atomic[int] # CAS coordination for consumers

  # Base queue type for SPMC
  # CC = ccMulti — multi-consumer pop coordinates via CAS, so the nim-debra
  # pin/retire contract requires the manager/handle axis to be ccMulti.
  UnboundedSipmucBase*[
    S: static int, T; MaxThreads: static int, CC: static PinScopeCardinality = ccMulti
  ] = object
    manager*: ptr DebraManager[MaxThreads, CC]
    headSegment*: ptr SPMCSegment[S, T]
    tailSegment*: ptr SPMCSegment[S, T]
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  SPMCPopContext*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object of RootObj
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT, CC]

  # States
  SPMCPopReady*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] =
    distinct SPMCPopContext[T, S, MT, CC]

  SPMCPopSegmentLoaded*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT, CC]
    segment*: ptr SPMCSegment[S, T]
    tail*: int
    prevConsumerIdx*: int

  SPMCPopSlotClaimed*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT, CC]
    segment*: ptr SPMCSegment[S, T]
    slot*: int

  SPMCPopSegmentExhausted*[
    T; S, MT: static int, CC: static PinScopeCardinality = ccMulti
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT, CC]
    segment*: ptr SPMCSegment[S, T]

  SPMCPopEmpty*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT, CC]

  SPMCPopComplete*[T; S, MT: static int, CC: static PinScopeCardinality = ccMulti] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT, CC]
    value*: T
    slot*: int
    isLastSlot*: bool

typestate SPMCPopContext[
  T, S: static int, MT: static int, CC: static PinScopeCardinality
]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  defaults:
    CC:
      ccMulti
  states SPMCPopReady[T, S, MT, CC],
    SPMCPopSegmentLoaded[T, S, MT, CC],
    SPMCPopSlotClaimed[T, S, MT, CC],
    SPMCPopSegmentExhausted[T, S, MT, CC],
    SPMCPopEmpty[T, S, MT, CC],
    SPMCPopComplete[T, S, MT, CC]
  transitions:
    SPMCPopReady[T, S, MT, CC] -> SPMCPopSegmentLoaded[T, S, MT, CC]
    SPMCPopSegmentLoaded[T, S, MT, CC] ->
      (
        SPMCPopSlotClaimed[T, S, MT, CC] | SPMCPopSegmentExhausted[T, S, MT, CC] |
        SPMCPopReady[T, S, MT, CC]
      ) as SPMCSlotClaimResult[T, S, MT, CC]
    SPMCPopSlotClaimed[T, S, MT, CC] -> SPMCPopComplete[T, S, MT, CC]
    SPMCPopSegmentExhausted[T, S, MT, CC] ->
      (SPMCPopReady[T, S, MT, CC] | SPMCPopEmpty[T, S, MT, CC]) as
      SPMCAdvanceResult[T, S, MT, CC]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int, CC: static PinScopeCardinality](
    pinned: sink Pinned[MT, CC], queue: ptr UnboundedSipmucBase[S, T, MT, CC]
): SPMCPopReady[T, S, MT, CC] =
  ## Create pop context from DEBRA's Pinned state.
  SPMCPopReady[T, S, MT, CC](
    SPMCPopContext[T, S, MT, CC](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: sink SPMCPopComplete[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: complete.pinnedHandle, epoch: complete.pinnedEpoch
    )
  )

proc extractPinned*[T; S, MT: static int, CC: static PinScopeCardinality](
    empty: sink SPMCPopEmpty[T, S, MT, CC]
): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    ready: sink SPMCPopReady[T, S, MT, CC]
): SPMCPopSegmentLoaded[T, S, MT, CC] {.transition.} =
  ## Load current head segment and positions.
  let ctx = SPMCPopContext[T, S, MT, CC](ready)
  let seg = ctx.queue.headSegment
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.prevConsumerIdx.load(moAcquire)

  SPMCPopSegmentLoaded[T, S, MT, CC](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    prevConsumerIdx: prevIdx,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int, CC: static PinScopeCardinality](
    loaded: sink SPMCPopSegmentLoaded[T, S, MT, CC]
): SPMCSlotClaimResult[T, S, MT, CC] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentExhausted: no more slots in segment
  ## - Ready: CAS failed, retry from beginning
  let seg = loaded.segment
  let mySlot = loaded.prevConsumerIdx + 1

  if mySlot >= loaded.tail:
    return
      SPMCSlotClaimResult[T, S, MT, CC] ->
      SPMCPopSegmentExhausted[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Try CAS
  var expected = loaded.prevConsumerIdx
  if seg.prevConsumerIdx.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    # Won the slot
    return
      SPMCSlotClaimResult[T, S, MT, CC] ->
      SPMCPopSlotClaimed[T, S, MT, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: mySlot,
      )
  else:
    # CAS failed - retry from beginning
    return
      SPMCSlotClaimResult[T, S, MT, CC] ->
      SPMCPopReady[T, S, MT, CC](
        SPMCPopContext[T, S, MT, CC](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Read item from claimed slot
proc readItem*[T; S, MT: static int, CC: static PinScopeCardinality](
    claimed: sink SPMCPopSlotClaimed[T, S, MT, CC]
): SPMCPopComplete[T, S, MT, CC] {.transition.} =
  ## Read item from claimed slot.
  let queue = claimed.queue
  let seg = claimed.segment
  let value = seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  SPMCPopComplete[T, S, MT, CC](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    value: value,
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1,
  )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int, CC: static PinScopeCardinality](
    exhausted: sink SPMCPopSegmentExhausted[T, S, MT, CC]
): SPMCAdvanceResult[T, S, MT, CC] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return
      SPMCAdvanceResult[T, S, MT, CC] ->
      SPMCPopEmpty[T, S, MT, CC](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  SPMCAdvanceResult[T, S, MT, CC] ->
    SPMCPopReady[T, S, MT, CC](
      SPMCPopContext[T, S, MT, CC](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Get value from completed pop
proc getValue*[T; S, MT: static int, CC: static PinScopeCardinality](
    complete: SPMCPopComplete[T, S, MT, CC]
): T {.notATransition.} =
  ## Extract the popped value.
  complete.value
