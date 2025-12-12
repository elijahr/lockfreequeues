## Typestate for unbounded SPSC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push, bridges back.

import atomics
import typestates
import debra

type
  # Forward declare Segment type (will import from parent module)
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr Segment[S, T]]
    head*: Atomic[int]
    tail*: Atomic[int]

  # Forward declare queue type
  UnboundedSipsicBase*[S: static int; T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr Segment[S, T]
    tailSegment*: ptr Segment[S, T]
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  SPSCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]

  # States
  SPSCPushReady*[T; S, MT: static int] = distinct SPSCPushContext[T, S, MT]

  SPSCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    segment*: ptr Segment[S, T]
    tail*: int

  SPSCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    segment*: ptr Segment[S, T]

  SPSCPushSlotReady*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]
    segment*: ptr Segment[S, T]
    slot*: int

  SPSCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipsicBase[S, T, MT]


typestate SPSCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states SPSCPushReady[T, S, MT], SPSCPushSegmentLoaded[T, S, MT],
         SPSCPushSegmentFull[T, S, MT], SPSCPushSlotReady[T, S, MT],
         SPSCPushComplete[T, S, MT]
  transitions:
    SPSCPushReady[T, S, MT] -> SPSCPushSegmentLoaded[T, S, MT]
    SPSCPushSegmentLoaded[T, S, MT] -> (SPSCPushSlotReady[T, S, MT] | SPSCPushSegmentFull[T, S, MT]) as SPSCSegmentCheck[T, S, MT]
    SPSCPushSegmentFull[T, S, MT] -> SPSCPushReady[T, S, MT]
    SPSCPushSlotReady[T, S, MT] -> SPSCPushComplete[T, S, MT]


# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipsicBase[S, T, MT]
): SPSCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  SPSCPushReady[T, S, MT](
    SPSCPushContext[T, S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: queue))


# Extract Pinned state from SPSCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
  complete: sink SPSCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


# Load segment transition
proc loadSegment*[T; S, MT: static int](
  ready: sink SPSCPushReady[T, S, MT]
): SPSCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = SPSCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  SPSCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail)


# Check full transition
proc checkFull*[T; S, MT: static int](
  loaded: sink SPSCPushSegmentLoaded[T, S, MT]
): SPSCSegmentCheck[T, S, MT] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull.
  if loaded.tail >= S:
    SPSCSegmentCheck[T, S, MT] -> SPSCPushSegmentFull[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)
  else:
    SPSCSegmentCheck[T, S, MT] -> SPSCPushSlotReady[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.tail)


# Allocate new segment transition
proc allocateNewSegment*[T; S, MT: static int](
  full: sink SPSCPushSegmentFull[T, S, MT],
  newSegment: ptr Segment[S, T]
): SPSCPushReady[T, S, MT] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  full.segment.next.store(newSegment, moRelease)
  full.queue.tailSegment = newSegment
  discard full.queue.segments.fetchAdd(1, moRelaxed)

  SPSCPushReady[T, S, MT](
    SPSCPushContext[T, S, MT](
      pinnedHandle: full.pinnedHandle,
      pinnedEpoch: full.pinnedEpoch,
      queue: full.queue))


# Write item transition
proc writeItem*[T; S, MT: static int](
  slotReady: sink SPSCPushSlotReady[T, S, MT],
  item: T
): SPSCPushComplete[T, S, MT] {.transition.} =
  ## Write item to slot and publish.
  slotReady.segment.data[slotReady.slot] = item
  slotReady.segment.tail.store(slotReady.slot + 1, moRelease)
  discard slotReady.queue.itemCount.fetchAdd(1, moRelaxed)

  SPSCPushComplete[T, S, MT](
    pinnedHandle: slotReady.pinnedHandle,
    pinnedEpoch: slotReady.pinnedEpoch,
    queue: slotReady.queue)
