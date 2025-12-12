## Typestate for unbounded SPMC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with CAS coordination,
## bridges back. Multiple consumers coordinate via CAS on prevConsumerIdx.

import atomics
import typestates
import debra

type
  # Segment type for SPMC - has prevConsumerIdx for CAS
  SPMCSegment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr SPMCSegment[S, T]]
    tail*: Atomic[int]  # Producer write position
    prevConsumerIdx*: Atomic[int]  # CAS coordination for consumers

  # Base queue type for SPMC
  UnboundedSipmucBase*[S: static int; T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr SPMCSegment[S, T]
    tailSegment*: ptr SPMCSegment[S, T]
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  SPMCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  # States
  SPMCPopReady*[T; S, MT: static int] = distinct SPMCPopContext[T, S, MT]

  SPMCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr SPMCSegment[S, T]
    tail*: int
    prevConsumerIdx*: int

  SPMCPopSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr SPMCSegment[S, T]
    slot*: int

  SPMCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr SPMCSegment[S, T]

  SPMCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  SPMCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    value*: T
    slot*: int
    isLastSlot*: bool


typestate SPMCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states SPMCPopReady[T, S, MT], SPMCPopSegmentLoaded[T, S, MT],
         SPMCPopSlotClaimed[T, S, MT], SPMCPopSegmentExhausted[T, S, MT],
         SPMCPopEmpty[T, S, MT], SPMCPopComplete[T, S, MT]
  transitions:
    SPMCPopReady[T, S, MT] -> SPMCPopSegmentLoaded[T, S, MT]
    SPMCPopSegmentLoaded[T, S, MT] -> (SPMCPopSlotClaimed[T, S, MT] | SPMCPopSegmentExhausted[T, S, MT] | SPMCPopReady[T, S, MT]) as SPMCSlotClaimResult[T, S, MT]
    SPMCPopSlotClaimed[T, S, MT] -> SPMCPopComplete[T, S, MT]
    SPMCPopSegmentExhausted[T, S, MT] -> (SPMCPopReady[T, S, MT] | SPMCPopEmpty[T, S, MT]) as SPMCAdvanceResult[T, S, MT]


# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipmucBase[S, T, MT]
): SPMCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  SPMCPopReady[T, S, MT](
    SPMCPopContext[T, S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: queue))


# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
  complete: sink SPMCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))

proc extractPinned*[T; S, MT: static int](
  empty: sink SPMCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: empty.pinnedHandle,
    epoch: empty.pinnedEpoch))


# Load segment transition
proc loadSegment*[T; S, MT: static int](
  ready: sink SPMCPopReady[T, S, MT]
): SPMCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = SPMCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.prevConsumerIdx.load(moAcquire)

  SPMCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    prevConsumerIdx: prevIdx)


# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
  loaded: sink SPMCPopSegmentLoaded[T, S, MT]
): SPMCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentExhausted: no more slots in segment
  ## - Ready: CAS failed, retry from beginning
  let seg = loaded.segment
  let mySlot = loaded.prevConsumerIdx + 1

  if mySlot >= loaded.tail:
    return SPMCSlotClaimResult[T, S, MT] -> SPMCPopSegmentExhausted[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # Try CAS
  var expected = loaded.prevConsumerIdx
  if seg.prevConsumerIdx.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    # Won the slot
    return SPMCSlotClaimResult[T, S, MT] -> SPMCPopSlotClaimed[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: mySlot)
  else:
    # CAS failed - retry from beginning
    return SPMCSlotClaimResult[T, S, MT] -> SPMCPopReady[T, S, MT](
      SPMCPopContext[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue))


# Read item from claimed slot
proc readItem*[T; S, MT: static int](
  claimed: sink SPMCPopSlotClaimed[T, S, MT]
): SPMCPopComplete[T, S, MT] {.transition.} =
  ## Read item from claimed slot.
  let queue = claimed.queue
  let seg = claimed.segment
  let value = seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  SPMCPopComplete[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    value: value,
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1)


# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
  exhausted: sink SPMCPopSegmentExhausted[T, S, MT]
): SPMCAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return SPMCAdvanceResult[T, S, MT] -> SPMCPopEmpty[T, S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue)

  SPMCAdvanceResult[T, S, MT] -> SPMCPopReady[T, S, MT](
    SPMCPopContext[T, S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue))


# Get value from completed pop
proc getValue*[T; S, MT: static int](
  complete: SPMCPopComplete[T, S, MT]
): T =
  ## Extract the popped value.
  complete.value
