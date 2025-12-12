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
  # Note: T is NOT in the typestate generic params - only S and MT matter for state tracking
  SPMCPopContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer  # Generic pointer to avoid T in context

  # States
  SPMCPopReady*[S, MT: static int] = distinct SPMCPopContext[S, MT]

  SPMCPopSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer  # Generic ptr SPMCSegment
    tail*: int
    prevConsumerIdx*: int

  SPMCPopSlotClaimed*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  SPMCPopSegmentExhausted*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  SPMCPopEmpty*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  SPMCPopComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    valuePtr*: pointer  # Generic pointer to value (caller extracts with type)
    slot*: int
    isLastSlot*: bool  # Whether this was slot S-1 (for retirement)


typestate SPMCPopContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false  # Typed wrappers don't use {.transition.}
  states SPMCPopReady[S, MT], SPMCPopSegmentLoaded[S, MT],
         SPMCPopSlotClaimed[S, MT], SPMCPopSegmentExhausted[S, MT],
         SPMCPopEmpty[S, MT], SPMCPopComplete[S, MT]
  transitions:
    SPMCPopReady[S, MT] -> SPMCPopSegmentLoaded[S, MT]
    SPMCPopSegmentLoaded[S, MT] -> (SPMCPopSlotClaimed[S, MT] | SPMCPopSegmentExhausted[S, MT] | SPMCPopReady[S, MT]) as SPMCSlotClaimResult[S, MT]
    SPMCPopSlotClaimed[S, MT] -> SPMCPopComplete[S, MT]
    SPMCPopSegmentExhausted[S, MT] -> (SPMCPopReady[S, MT] | SPMCPopEmpty[S, MT]) as SPMCAdvanceResult[S, MT]


# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipmucBase[S, T, MT]
): SPMCPopReady[S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  SPMCPopReady[S, MT](
    SPMCPopContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


# Extract Pinned state from terminal states
proc extractPinned*[S, MT: static int](
  complete: sink SPMCPopComplete[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))

proc extractPinned*[S, MT: static int](
  empty: sink SPMCPopEmpty[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: empty.pinnedHandle,
    epoch: empty.pinnedEpoch))


# Load segment transition
proc loadSegment*[S, MT: static int](
  ready: sink SPMCPopReady[S, MT]
): SPMCPopSegmentLoaded[S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = SPMCPopContext[S, MT](ready)
  SPMCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,
    tail: 0,
    prevConsumerIdx: 0)


# Typed version that actually loads the segment
proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink SPMCPopReady[S, MT]
): SPMCPopSegmentLoaded[S, MT] =
  ## Load current head segment and positions (typed version).
  let ctx = SPMCPopContext[S, MT](ready)
  let queue = cast[ptr UnboundedSipmucBase[S, T, MT]](ctx.queue)
  let seg = queue.headSegment
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.prevConsumerIdx.load(moAcquire)

  SPMCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    tail: tail,
    prevConsumerIdx: prevIdx)


# Try to claim slot with CAS
proc tryClaimSlot*[S, MT: static int](
  loaded: sink SPMCPopSegmentLoaded[S, MT]
): SPMCSlotClaimResult[S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentExhausted: no more slots in segment
  ## - Ready: CAS failed, retry from beginning
  let mySlot = loaded.prevConsumerIdx + 1
  if mySlot >= loaded.tail:
    return SPMCSlotClaimResult[S, MT] -> SPMCPopSegmentExhausted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # CAS logic done in typed version - default to retry
  SPMCSlotClaimResult[S, MT] -> SPMCPopReady[S, MT](
    SPMCPopContext[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue))


# Typed version with actual CAS
proc tryClaimSlotTyped*[T; S, MT: static int](
  loaded: sink SPMCPopSegmentLoaded[S, MT]
): SPMCSlotClaimResult[S, MT] =
  ## Try to claim a slot using CAS (typed version).
  let seg = cast[ptr SPMCSegment[S, T]](loaded.segment)
  let mySlot = loaded.prevConsumerIdx + 1

  if mySlot >= loaded.tail:
    return SPMCSlotClaimResult[S, MT] -> SPMCPopSegmentExhausted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # Try CAS
  var expected = loaded.prevConsumerIdx
  if seg.prevConsumerIdx.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    # Won the slot
    return SPMCSlotClaimResult[S, MT] -> SPMCPopSlotClaimed[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: mySlot)
  else:
    # CAS failed - retry from beginning
    return SPMCSlotClaimResult[S, MT] -> SPMCPopReady[S, MT](
      SPMCPopContext[S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue))


# Read item from claimed slot
proc readItem*[S, MT: static int](
  claimed: sink SPMCPopSlotClaimed[S, MT]
): SPMCPopComplete[S, MT] {.transition.} =
  ## Read item from claimed slot. Actual read done by typed wrapper.
  SPMCPopComplete[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    valuePtr: nil,
    slot: claimed.slot,
    isLastSlot: false)


# Typed version that actually reads the item
proc readItemTyped*[T; S, MT: static int](
  claimed: sink SPMCPopSlotClaimed[S, MT]
): SPMCPopComplete[S, MT] =
  ## Read item from claimed slot (typed version).
  let queue = cast[ptr UnboundedSipmucBase[S, T, MT]](claimed.queue)
  let seg = cast[ptr SPMCSegment[S, T]](claimed.segment)
  let valuePtr = addr seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  SPMCPopComplete[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    valuePtr: cast[pointer](valuePtr),
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1)


# Advance segment transition
proc advanceSegment*[S, MT: static int](
  exhausted: sink SPMCPopSegmentExhausted[S, MT]
): SPMCAdvanceResult[S, MT] {.transition.} =
  ## Try to advance to next segment.
  SPMCAdvanceResult[S, MT] -> SPMCPopEmpty[S, MT](
    pinnedHandle: exhausted.pinnedHandle,
    pinnedEpoch: exhausted.pinnedEpoch,
    queue: exhausted.queue)


# Typed version that actually advances the segment
proc advanceSegmentTyped*[T; S, MT: static int](
  exhausted: sink SPMCPopSegmentExhausted[S, MT]
): SPMCAdvanceResult[S, MT] =
  ## Try to advance to next segment (typed version).
  let seg = cast[ptr SPMCSegment[S, T]](exhausted.segment)
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return SPMCAdvanceResult[S, MT] -> SPMCPopEmpty[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue)

  # Note: Segment advancement and retirement handled by caller
  # Just return Ready with the next segment context
  SPMCAdvanceResult[S, MT] -> SPMCPopReady[S, MT](
    SPMCPopContext[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue))


# Get value from completed pop
proc getValue*[T; S, MT: static int](
  complete: SPMCPopComplete[S, MT]
): T =
  ## Extract the popped value.
  cast[ptr T](complete.valuePtr)[]
