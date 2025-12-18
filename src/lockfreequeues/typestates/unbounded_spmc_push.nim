## Typestate for unbounded SPMC push operations.
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
    tail*: Atomic[int]
    prevConsumerIdx*: Atomic[int]

  # Forward declare queue type
  UnboundedSipmuc*[S: static int; T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr Segment[S, T]
    tailSegment*: ptr Segment[S, T]
    strategy*: int  # DeallocationStrategy enum
    itemCount*: Atomic[int]
    segments*: Atomic[int]
    consumerCount*: Atomic[int]
    consumerHeads*: array[MaxThreads, Atomic[int]]

  # Base context - carries pinned state and queue pointer
  SPMCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT]

  # States
  SPMCPushReady*[T; S, MT: static int] = distinct SPMCPushContext[T, S, MT]

  SPMCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT]
    segment*: ptr Segment[S, T]
    tail*: int

  SPMCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT]
    segment*: ptr Segment[S, T]

  SPMCPushSlotReady*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT]
    segment*: ptr Segment[S, T]
    slot*: int

  SPMCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT]


typestate SPMCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states SPMCPushReady[T, S, MT], SPMCPushSegmentLoaded[T, S, MT],
         SPMCPushSegmentFull[T, S, MT], SPMCPushSlotReady[T, S, MT],
         SPMCPushComplete[T, S, MT]
  transitions:
    SPMCPushReady[T, S, MT] -> SPMCPushSegmentLoaded[T, S, MT]
    SPMCPushSegmentLoaded[T, S, MT] -> (SPMCPushSlotReady[T, S, MT] | SPMCPushSegmentFull[T, S, MT]) as SPMCSegmentCheck[T, S, MT]
    SPMCPushSegmentFull[T, S, MT] -> SPMCPushReady[T, S, MT]
    SPMCPushSlotReady[T, S, MT] -> SPMCPushComplete[T, S, MT]


# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipmuc[S, T, MT]
): SPMCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  SPMCPushReady[T, S, MT](
    SPMCPushContext[T, S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: queue))


# Extract Pinned state from SPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
  complete: sink SPMCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


# Load segment transition
proc loadSegment*[T; S, MT: static int](
  ready: sink SPMCPushReady[T, S, MT]
): SPMCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = SPMCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  SPMCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail)


# Check full transition
proc checkFull*[T; S, MT: static int](
  loaded: sink SPMCPushSegmentLoaded[T, S, MT]
): SPMCSegmentCheck[T, S, MT] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull.
  if loaded.tail >= S:
    SPMCSegmentCheck[T, S, MT] -> SPMCPushSegmentFull[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)
  else:
    SPMCSegmentCheck[T, S, MT] -> SPMCPushSlotReady[T, S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.tail)


# Allocate new segment transition
proc allocateNewSegment*[T; S, MT: static int](
  full: sink SPMCPushSegmentFull[T, S, MT],
  newSegment: ptr Segment[S, T]
): SPMCPushReady[T, S, MT] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  full.segment.next.store(newSegment, moRelease)
  full.queue.tailSegment = newSegment
  discard full.queue.segments.fetchAdd(1, moRelaxed)

  SPMCPushReady[T, S, MT](
    SPMCPushContext[T, S, MT](
      pinnedHandle: full.pinnedHandle,
      pinnedEpoch: full.pinnedEpoch,
      queue: full.queue))


# Write item transition
proc writeItem*[T; S, MT: static int](
  slotReady: sink SPMCPushSlotReady[T, S, MT],
  item: T
): SPMCPushComplete[T, S, MT] {.transition.} =
  ## Write item to slot and publish.
  slotReady.segment.data[slotReady.slot] = item
  slotReady.segment.tail.store(slotReady.slot + 1, moRelease)
  discard slotReady.queue.itemCount.fetchAdd(1, moRelaxed)

  SPMCPushComplete[T, S, MT](
    pinnedHandle: slotReady.pinnedHandle,
    pinnedEpoch: slotReady.pinnedEpoch,
    queue: slotReady.queue)
