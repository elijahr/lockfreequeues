## Typestate for unbounded SPSC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop, bridges back.

import atomics
import typestates
import debra

import ./unbounded_spsc_push  # Reuse Segment, UnboundedSipsicBase

type
  # Base context - carries pinned state and queue pointer
  # Note: T is NOT in the typestate generic params - only S and MT matter for state tracking
  SPSCPopContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer  # Generic pointer to avoid T in context

  # States
  SPSCPopReady*[S, MT: static int] = distinct SPSCPopContext[S, MT]

  SPSCPopSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer  # Generic ptr Segment
    head*: int
    tail*: int

  SPSCPopSlotAvailable*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  SPSCPopSegmentExhausted*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  SPSCPopEmpty*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  SPSCPopComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    valuePtr*: pointer  # Generic pointer to value (caller extracts with type)
    slot*: int


typestate SPSCPopContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false  # Typed wrappers don't use {.transition.}
  states SPSCPopReady[S, MT], SPSCPopSegmentLoaded[S, MT],
         SPSCPopSlotAvailable[S, MT], SPSCPopSegmentExhausted[S, MT],
         SPSCPopEmpty[S, MT], SPSCPopComplete[S, MT]
  transitions:
    SPSCPopReady[S, MT] -> SPSCPopSegmentLoaded[S, MT]
    SPSCPopSegmentLoaded[S, MT] -> (SPSCPopSlotAvailable[S, MT] | SPSCPopSegmentExhausted[S, MT]) as SPSCSlotCheck[S, MT]
    SPSCPopSegmentExhausted[S, MT] -> (SPSCPopReady[S, MT] | SPSCPopEmpty[S, MT]) as SPSCAdvanceResult[S, MT]
    SPSCPopSlotAvailable[S, MT] -> SPSCPopComplete[S, MT]


# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipsicBase[S, T, MT]
): SPSCPopReady[S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  SPSCPopReady[S, MT](
    SPSCPopContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


# Extract Pinned state from SPSCPopComplete for unpinning
proc extractPinned*[S, MT: static int](
  complete: sink SPSCPopComplete[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


# Extract Pinned state from SPSCPopEmpty for unpinning
proc extractPinned*[S, MT: static int](
  empty: sink SPSCPopEmpty[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: empty.pinnedHandle,
    epoch: empty.pinnedEpoch))


# Load segment transition
proc loadSegment*[S, MT: static int](
  ready: sink SPSCPopReady[S, MT]
): SPSCPopSegmentLoaded[S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = SPSCPopContext[S, MT](ready)
  SPSCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,  # Will be set by typed wrapper
    head: 0,       # Will be set by typed wrapper
    tail: 0)       # Will be set by typed wrapper


# Typed version that actually loads the segment
proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink SPSCPopReady[S, MT]
): SPSCPopSegmentLoaded[S, MT] =
  ## Load current head segment and positions (typed version).
  let ctx = SPSCPopContext[S, MT](ready)
  let queue = cast[ptr UnboundedSipsicBase[S, T, MT]](ctx.queue)
  let seg = queue.headSegment
  let head = seg.head.load(moRelaxed)
  let tail = seg.tail.load(moAcquire)

  SPSCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    head: head,
    tail: tail)


# Check slot availability transition
proc checkSlot*[S, MT: static int](
  loaded: sink SPSCPopSegmentLoaded[S, MT]
): SPSCSlotCheck[S, MT] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    SPSCSlotCheck[S, MT] -> SPSCPopSlotAvailable[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.head)
  else:
    SPSCSlotCheck[S, MT] -> SPSCPopSegmentExhausted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)


# Advance segment transition
proc advanceSegment*[S, MT: static int](
  exhausted: sink SPSCPopSegmentExhausted[S, MT]
): SPSCAdvanceResult[S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  ## Note: Actual segment advancement done by typed wrapper.
  SPSCAdvanceResult[S, MT] -> SPSCPopEmpty[S, MT](
    pinnedHandle: exhausted.pinnedHandle,
    pinnedEpoch: exhausted.pinnedEpoch,
    queue: exhausted.queue)


# Typed version that actually advances the segment
proc advanceSegmentTyped*[T; S, MT: static int](
  exhausted: sink SPSCPopSegmentExhausted[S, MT]
): SPSCAdvanceResult[S, MT] =
  ## Try to advance to next segment (typed version).
  let queue = cast[ptr UnboundedSipsicBase[S, T, MT]](exhausted.queue)
  let seg = cast[ptr Segment[S, T]](exhausted.segment)
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return SPSCAdvanceResult[S, MT] -> SPSCPopEmpty[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue)

  # Advance head segment
  queue.headSegment = nextSeg
  # Note: Segment retirement handled by caller

  SPSCAdvanceResult[S, MT] -> SPSCPopReady[S, MT](
    SPSCPopContext[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue))


# Read item transition
proc readItem*[S, MT: static int](
  slotAvail: sink SPSCPopSlotAvailable[S, MT]
): SPSCPopComplete[S, MT] {.transition.} =
  ## Mark item as read (actual read done by typed wrapper).
  SPSCPopComplete[S, MT](
    pinnedHandle: slotAvail.pinnedHandle,
    pinnedEpoch: slotAvail.pinnedEpoch,
    queue: slotAvail.queue,
    valuePtr: nil,  # Will be set by typed wrapper
    slot: slotAvail.slot)


# Typed version that actually reads the item
proc readItemTyped*[T; S, MT: static int](
  slotAvail: sink SPSCPopSlotAvailable[S, MT]
): SPSCPopComplete[S, MT] =
  ## Read item from slot and advance head (typed version).
  let queue = cast[ptr UnboundedSipsicBase[S, T, MT]](slotAvail.queue)
  let seg = cast[ptr Segment[S, T]](slotAvail.segment)

  # Read value before advancing head
  let valuePtr = addr seg.data[slotAvail.slot]

  # Advance head
  seg.head.store(slotAvail.slot + 1, moRelaxed)
  discard queue.itemCount.fetchSub(1, moRelaxed)

  SPSCPopComplete[S, MT](
    pinnedHandle: slotAvail.pinnedHandle,
    pinnedEpoch: slotAvail.pinnedEpoch,
    queue: slotAvail.queue,
    valuePtr: cast[pointer](valuePtr),
    slot: slotAvail.slot)


# Get value from completed pop
proc getValue*[T; S, MT: static int](
  complete: SPSCPopComplete[S, MT]
): T =
  ## Extract the popped value.
  cast[ptr T](complete.valuePtr)[]
