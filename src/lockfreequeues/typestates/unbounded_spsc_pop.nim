## Typestate for unbounded SPSC pop operations.
##
## SPSC doesn't need DEBRA - single producer/consumer means no hazardous
## memory reclamation. Consumer can free segments directly with dealloc.
## Uses 'U' prefix (Unbounded) to avoid name collision with bounded spsc_pop.

import atomics
import typestates

import ./unbounded_spsc_push # Reuse Segment, UnboundedSipsicBase

type
  # Base context - carries queue pointer
  USPSCPopContext*[T; S: static int] = object of RootObj
    queue*: ptr UnboundedSipsicBase[S, T]

  # States (prefixed with U for Unbounded to avoid collision)
  USPSCPopReady*[T; S: static int] = distinct USPSCPopContext[T, S]

  USPSCPopSegmentLoaded*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    segment*: ptr Segment[S, T]
    head*: int
    tail*: int

  USPSCPopSlotAvailable*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    segment*: ptr Segment[S, T]
    slot*: int

  USPSCPopSegmentExhausted*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    segment*: ptr Segment[S, T]

  USPSCPopEmpty*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]

  USPSCPopComplete*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    value*: T
    slot*: int
    oldSegment*: ptr Segment[S, T] # Segment to free if exhausted

typestate USPSCPopContext[T, S: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states USPSCPopReady[T, S],
    USPSCPopSegmentLoaded[T, S],
    USPSCPopSlotAvailable[T, S],
    USPSCPopSegmentExhausted[T, S],
    USPSCPopEmpty[T, S],
    USPSCPopComplete[T, S]
  transitions:
    USPSCPopReady[T, S] -> USPSCPopSegmentLoaded[T, S]
    USPSCPopSegmentLoaded[T, S] ->
      (USPSCPopSlotAvailable[T, S] | USPSCPopSegmentExhausted[T, S]) as
      USPSCSlotCheck[T, S]
    USPSCPopSegmentExhausted[T, S] ->
      (USPSCPopReady[T, S] | USPSCPopEmpty[T, S]) as USPSCAdvanceResult[T, S]
    USPSCPopSlotAvailable[T, S] -> USPSCPopComplete[T, S]

# Factory: Create pop typestate context
proc startPop*[T; S: static int](
    queue: ptr UnboundedSipsicBase[S, T]
): USPSCPopReady[T, S] =
  ## Create pop context for the queue.
  USPSCPopReady[T, S](USPSCPopContext[T, S](queue: queue))

# Load segment transition
proc loadSegment*[T; S: static int](
    ready: sink USPSCPopReady[T, S]
): USPSCPopSegmentLoaded[T, S] {.transition.} =
  ## Load current head segment and positions.
  let ctx = USPSCPopContext[T, S](ready)
  let seg = ctx.queue.headSegment
  let head = seg.head.load(moRelaxed)
  let tail = seg.tail.load(moAcquire)

  USPSCPopSegmentLoaded[T, S](queue: ctx.queue, segment: seg, head: head, tail: tail)

# Check slot availability transition
proc checkSlot*[T; S: static int](
    loaded: sink USPSCPopSegmentLoaded[T, S]
): USPSCSlotCheck[T, S] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    USPSCSlotCheck[T, S] ->
      USPSCPopSlotAvailable[T, S](
        queue: loaded.queue, segment: loaded.segment, slot: loaded.head
      )
  else:
    USPSCSlotCheck[T, S] ->
      USPSCPopSegmentExhausted[T, S](queue: loaded.queue, segment: loaded.segment)

# Advance segment transition
proc advanceSegment*[T; S: static int](
    exhausted: sink USPSCPopSegmentExhausted[T, S]
): USPSCAdvanceResult[T, S] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  ## Note: Caller is responsible for freeing the old segment (returned in oldSegment field).
  let nextSeg = exhausted.segment.next.load(moAcquire)

  if nextSeg == nil:
    return USPSCAdvanceResult[T, S] -> USPSCPopEmpty[T, S](queue: exhausted.queue)

  # Advance head segment (caller should dealloc old segment)
  exhausted.queue.headSegment = nextSeg
  discard exhausted.queue.segments.fetchSub(1, moRelaxed)

  USPSCAdvanceResult[T, S] ->
    USPSCPopReady[T, S](USPSCPopContext[T, S](queue: exhausted.queue))

# Read item transition
proc readItem*[T; S: static int](
    slotAvail: sink USPSCPopSlotAvailable[T, S]
): USPSCPopComplete[T, S] {.transition.} =
  ## Read item from slot and advance head.
  # Read value before advancing head
  let value = slotAvail.segment.data[slotAvail.slot]

  # Advance head
  slotAvail.segment.head.store(slotAvail.slot + 1, moRelaxed)
  discard slotAvail.queue.itemCount.fetchSub(1, moRelaxed)

  USPSCPopComplete[T, S](
    queue: slotAvail.queue, value: value, slot: slotAvail.slot, oldSegment: nil
  )

# Get value from completed pop
proc getValue*[T; S: static int](complete: USPSCPopComplete[T, S]): T =
  ## Extract the popped value.
  complete.value
