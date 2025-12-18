## Typestate for unbounded SPSC push operations.
##
## SPSC doesn't need DEBRA - single producer/consumer means no hazardous
## memory reclamation. Consumer can free segments directly with dealloc.

import atomics
import typestates

type
  # Forward declare Segment type (matches parent module)
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr Segment[S, T]]
    head*: Atomic[int]
    tail*: Atomic[int]

  # Forward declare queue type (no DEBRA for SPSC)
  UnboundedSipsicBase*[S: static int; T] = object
    headSegment*: ptr Segment[S, T]
    tailSegment*: ptr Segment[S, T]
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries queue pointer
  SPSCPushContext*[T; S: static int] = object of RootObj
    queue*: ptr UnboundedSipsicBase[S, T]

  # States
  SPSCPushReady*[T; S: static int] = distinct SPSCPushContext[T, S]

  SPSCPushSegmentLoaded*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    segment*: ptr Segment[S, T]
    tail*: int

  SPSCPushSegmentFull*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    segment*: ptr Segment[S, T]

  SPSCPushSlotReady*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]
    segment*: ptr Segment[S, T]
    slot*: int

  SPSCPushComplete*[T; S: static int] = object
    queue*: ptr UnboundedSipsicBase[S, T]


typestate SPSCPushContext[T, S: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states SPSCPushReady[T, S], SPSCPushSegmentLoaded[T, S],
         SPSCPushSegmentFull[T, S], SPSCPushSlotReady[T, S],
         SPSCPushComplete[T, S]
  transitions:
    SPSCPushReady[T, S] -> SPSCPushSegmentLoaded[T, S]
    SPSCPushSegmentLoaded[T, S] -> (SPSCPushSlotReady[T, S] | SPSCPushSegmentFull[T, S]) as SPSCSegmentCheck[T, S]
    SPSCPushSegmentFull[T, S] -> SPSCPushReady[T, S]
    SPSCPushSlotReady[T, S] -> SPSCPushComplete[T, S]


# Factory: Create push typestate context
proc startPush*[T; S: static int](
  queue: ptr UnboundedSipsicBase[S, T]
): SPSCPushReady[T, S] =
  ## Create push context for the queue.
  SPSCPushReady[T, S](
    SPSCPushContext[T, S](
      queue: queue))


# Load segment transition
proc loadSegment*[T; S: static int](
  ready: sink SPSCPushReady[T, S]
): SPSCPushSegmentLoaded[T, S] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = SPSCPushContext[T, S](ready)
  let seg = ctx.queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  SPSCPushSegmentLoaded[T, S](
    queue: ctx.queue,
    segment: seg,
    tail: tail)


# Check full transition
proc checkFull*[T; S: static int](
  loaded: sink SPSCPushSegmentLoaded[T, S]
): SPSCSegmentCheck[T, S] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull.
  if loaded.tail >= S:
    SPSCSegmentCheck[T, S] -> SPSCPushSegmentFull[T, S](
      queue: loaded.queue,
      segment: loaded.segment)
  else:
    SPSCSegmentCheck[T, S] -> SPSCPushSlotReady[T, S](
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.tail)


# Allocate new segment transition
proc allocateNewSegment*[T; S: static int](
  full: sink SPSCPushSegmentFull[T, S],
  newSegment: ptr Segment[S, T]
): SPSCPushReady[T, S] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  full.segment.next.store(newSegment, moRelease)
  full.queue.tailSegment = newSegment
  discard full.queue.segments.fetchAdd(1, moRelaxed)

  SPSCPushReady[T, S](
    SPSCPushContext[T, S](
      queue: full.queue))


# Write item transition
proc writeItem*[T; S: static int](
  slotReady: sink SPSCPushSlotReady[T, S],
  item: T
): SPSCPushComplete[T, S] {.transition.} =
  ## Write item to slot and publish.
  slotReady.segment.data[slotReady.slot] = item
  slotReady.segment.tail.store(slotReady.slot + 1, moRelease)
  discard slotReady.queue.itemCount.fetchAdd(1, moRelaxed)

  SPSCPushComplete[T, S](
    queue: slotReady.queue)
