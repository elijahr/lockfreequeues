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
  # Note: T is NOT in the typestate generic params - only S and MT matter for state tracking
  SPSCPushContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer  # Generic pointer to avoid T in context

  # States
  SPSCPushReady*[S, MT: static int] = distinct SPSCPushContext[S, MT]

  SPSCPushSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer  # Generic ptr Segment
    tail*: int

  SPSCPushSegmentFull*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  SPSCPushSlotReady*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  SPSCPushComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer


typestate SPSCPushContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false  # Typed wrappers don't use {.transition.}
  states SPSCPushReady[S, MT], SPSCPushSegmentLoaded[S, MT],
         SPSCPushSegmentFull[S, MT], SPSCPushSlotReady[S, MT],
         SPSCPushComplete[S, MT]
  transitions:
    SPSCPushReady[S, MT] -> SPSCPushSegmentLoaded[S, MT]
    SPSCPushSegmentLoaded[S, MT] -> (SPSCPushSlotReady[S, MT] | SPSCPushSegmentFull[S, MT]) as SPSCSegmentCheck[S, MT]
    SPSCPushSegmentFull[S, MT] -> SPSCPushReady[S, MT]
    SPSCPushSlotReady[S, MT] -> SPSCPushComplete[S, MT]


# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedSipsicBase[S, T, MT]
): SPSCPushReady[S, MT] =
  ## Create push context from DEBRA's Pinned state.
  SPSCPushReady[S, MT](
    SPSCPushContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


# Extract Pinned state from SPSCPushComplete for unpinning
proc extractPinned*[S, MT: static int](
  complete: sink SPSCPushComplete[S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


# Load segment transition
proc loadSegment*[S, MT: static int](
  ready: sink SPSCPushReady[S, MT]
): SPSCPushSegmentLoaded[S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = SPSCPushContext[S, MT](ready)
  # Note: We need to cast back to the concrete type when accessing queue fields
  # The caller must provide T at the call site
  SPSCPushSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,  # Will be set by typed wrapper
    tail: 0)       # Will be set by typed wrapper


# Typed version that actually loads the segment
proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink SPSCPushReady[S, MT]
): SPSCPushSegmentLoaded[S, MT] =
  ## Load current tail segment and tail position (typed version).
  let ctx = SPSCPushContext[S, MT](ready)
  let queue = cast[ptr UnboundedSipsicBase[S, T, MT]](ctx.queue)
  let seg = queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  SPSCPushSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    tail: tail)


# Check full transition
proc checkFull*[S, MT: static int](
  loaded: sink SPSCPushSegmentLoaded[S, MT]
): SPSCSegmentCheck[S, MT] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull.
  if loaded.tail >= S:
    SPSCSegmentCheck[S, MT] -> SPSCPushSegmentFull[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)
  else:
    SPSCSegmentCheck[S, MT] -> SPSCPushSlotReady[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: loaded.tail)


# Allocate new segment transition
proc allocateNewSegment*[S, MT: static int](
  full: sink SPSCPushSegmentFull[S, MT],
  newSegment: pointer
): SPSCPushReady[S, MT] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  ## Caller must allocate the segment before calling.
  # Note: This transition doesn't know about T, so caller must handle allocation
  SPSCPushReady[S, MT](
    SPSCPushContext[S, MT](
      pinnedHandle: full.pinnedHandle,
      pinnedEpoch: full.pinnedEpoch,
      queue: full.queue))


# Typed version that actually links the segment
proc allocateNewSegmentTyped*[T; S, MT: static int](
  full: sink SPSCPushSegmentFull[S, MT],
  newSegment: ptr Segment[S, T]
): SPSCPushReady[S, MT] =
  ## Link new segment and return to Ready state to retry (typed version).
  let queue = cast[ptr UnboundedSipsicBase[S, T, MT]](full.queue)
  let oldSeg = cast[ptr Segment[S, T]](full.segment)
  oldSeg.next.store(newSegment, moRelease)
  queue.tailSegment = newSegment
  discard queue.segments.fetchAdd(1, moRelaxed)

  SPSCPushReady[S, MT](
    SPSCPushContext[S, MT](
      pinnedHandle: full.pinnedHandle,
      pinnedEpoch: full.pinnedEpoch,
      queue: full.queue))


# Write item transition
proc writeItem*[S, MT: static int](
  slotReady: sink SPSCPushSlotReady[S, MT]
): SPSCPushComplete[S, MT] {.transition.} =
  ## Mark slot as written (item must be written by typed wrapper first).
  SPSCPushComplete[S, MT](
    pinnedHandle: slotReady.pinnedHandle,
    pinnedEpoch: slotReady.pinnedEpoch,
    queue: slotReady.queue)


# Typed version that actually writes the item
# Note: T must come first in generic params to avoid "type expected" error
proc writeItemTyped*[T; S, MT: static int](
  slotReady: sink SPSCPushSlotReady[S, MT],
  item: T
): SPSCPushComplete[S, MT] =
  ## Write item to slot and publish (typed version).
  let queue = cast[ptr UnboundedSipsicBase[S, T, MT]](slotReady.queue)
  let seg = cast[ptr Segment[S, T]](slotReady.segment)
  seg.data[slotReady.slot] = item
  seg.tail.store(slotReady.slot + 1, moRelease)
  discard queue.itemCount.fetchAdd(1, moRelaxed)

  SPSCPushComplete[S, MT](
    pinnedHandle: slotReady.pinnedHandle,
    pinnedEpoch: slotReady.pinnedEpoch,
    queue: slotReady.queue)
