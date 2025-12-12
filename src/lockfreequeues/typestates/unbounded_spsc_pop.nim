## Typestate for unbounded SPSC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop, bridges back.
## Uses 'U' prefix (Unbounded) to avoid name collision with bounded spsc_pop.

import atomics
import typestates
import debra

import ./unbounded_spsc_push  # Reuse Segment, UnboundedSipsicBase

type
  # Base context - carries pinned state and queue pointer
  USPSCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]

  # States (prefixed with U for Unbounded to avoid collision)
  USPSCPopReady*[T; S, MT: static int] = distinct USPSCPopContext[T, S, MT]

  USPSCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    segment*: ptr Segment[S, T]
    head*: int
    tail*: int

  USPSCPopSlotAvailable*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    segment*: ptr Segment[S, T]
    slot*: int

  USPSCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    segment*: ptr Segment[S, T]

  USPSCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]

  USPSCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    value*: T
    slot*: int


typestate USPSCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false  # Allow values to be passed across case branches
  states USPSCPopReady[T, S, MT], USPSCPopSegmentLoaded[T, S, MT],
         USPSCPopSlotAvailable[T, S, MT], USPSCPopSegmentExhausted[T, S, MT],
         USPSCPopEmpty[T, S, MT], USPSCPopComplete[T, S, MT]
  transitions:
    USPSCPopReady[T, S, MT] -> USPSCPopSegmentLoaded[T, S, MT]
    USPSCPopSegmentLoaded[T, S, MT] -> (USPSCPopSlotAvailable[T, S, MT] | USPSCPopSegmentExhausted[T, S, MT]) as USPSCSlotCheck[T, S, MT]
    USPSCPopSegmentExhausted[T, S, MT] -> (USPSCPopReady[T, S, MT] | USPSCPopEmpty[T, S, MT]) as USPSCAdvanceResult[T, S, MT]
    USPSCPopSlotAvailable[T, S, MT] -> USPSCPopComplete[T, S, MT]


# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipsicBase[S, T, MT]
): USPSCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  USPSCPopReady[T, S, MT](
    USPSCPopContext[T, S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: queue))


# Extract Pinned state from USPSCPopComplete for unpinning
proc extractPinned*[T; S, MT: static int](
  complete: sink USPSCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


# Extract Pinned state from USPSCPopEmpty for unpinning
proc extractPinned*[T; S, MT: static int](
  empty: sink USPSCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: empty.pinnedHandle,
    epoch: empty.pinnedEpoch))


# Load segment transition
proc loadSegment*[T; S, MT: static int](
  ready: sink USPSCPopReady[T, S, MT]
): USPSCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = USPSCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment
  let head = seg.head.load(moRelaxed)
  let tail = seg.tail.load(moAcquire)

  USPSCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    head: head,
    tail: tail)


# Check slot availability transition
proc checkSlot*[T; S, MT: static int](
  loaded: sink USPSCPopSegmentLoaded[T, S, MT]
): USPSCSlotCheck[T, S, MT] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    USPSCSlotCheck[T, S, MT] -> USPSCPopSlotAvailable[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.head)
  else:
    USPSCSlotCheck[T, S, MT] -> USPSCPopSegmentExhausted[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)


# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
  exhausted: sink USPSCPopSegmentExhausted[T, S, MT]
): USPSCAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let nextSeg = exhausted.segment.next.load(moAcquire)

  if nextSeg == nil:
    return USPSCAdvanceResult[T, S, MT] -> USPSCPopEmpty[T, S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue)

  # Advance head segment
  exhausted.queue.headSegment = nextSeg
  # Note: Segment retirement handled by caller

  USPSCAdvanceResult[T, S, MT] -> USPSCPopReady[T, S, MT](
    USPSCPopContext[T, S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue))


# Read item transition
proc readItem*[T; S, MT: static int](
  slotAvail: sink USPSCPopSlotAvailable[T, S, MT]
): USPSCPopComplete[T, S, MT] {.transition.} =
  ## Read item from slot and advance head.
  # Read value before advancing head
  let value = slotAvail.segment.data[slotAvail.slot]

  # Advance head
  slotAvail.segment.head.store(slotAvail.slot + 1, moRelaxed)
  discard slotAvail.queue.itemCount.fetchSub(1, moRelaxed)

  USPSCPopComplete[T, S, MT](
    pinnedHandle: slotAvail.pinnedHandle,
    pinnedEpoch: slotAvail.pinnedEpoch,
    queue: slotAvail.queue,
    value: value,
    slot: slotAvail.slot)


# Get value from completed pop
proc getValue*[T; S, MT: static int](
  complete: USPSCPopComplete[T, S, MT]
): T =
  ## Extract the popped value.
  complete.value
