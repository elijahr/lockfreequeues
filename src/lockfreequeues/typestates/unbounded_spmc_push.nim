## Typestate for unbounded SPMC push operations.
##
## Bridges from DEBRA's Pinned[MT, CC] state, performs push, bridges back.

import ../atomic_dsl
import ../strategy
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
  #
  # ST: static DeallocationStrategy phantom replaces the previous
  # `strategy*: int` runtime field (Step 3.3.5 per Doc C §3.6). Sites that
  # depended on the runtime field now use `when ST == stEager` /
  # `when ST == stManual` compile-time gates.
  #
  # CC: static PinScopeCardinality = ccMulti — this scaffold is a SIPMUC
  # (Single Producer Multiple Consumer) base; the consumer side requires
  # ccMulti for the nim-debra pin/retire contract, so the manager and
  # any derived ThreadHandle/Pinned values are ccMulti.
  UnboundedSipmuc*[
    S: static int,
    T;
    MaxThreads: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = object
    manager*: ptr DebraManager[MaxThreads, CC]
    headSegment*: ptr Segment[S, T]
    tailSegment*: ptr Segment[S, T]
    itemCount*: Atomic[int]
    segments*: Atomic[int]
    consumerCount*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  SPMCPushContext*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = object of RootObj
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT, ST, CC]

  # States
  SPMCPushReady*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = distinct SPMCPushContext[T, S, MT, ST, CC]

  SPMCPushSegmentLoaded*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT, ST, CC]
    segment*: ptr Segment[S, T]
    tail*: int

  SPMCPushSegmentFull*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT, ST, CC]
    segment*: ptr Segment[S, T]

  SPMCPushSlotReady*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT, ST, CC]
    segment*: ptr Segment[S, T]
    slot*: int

  SPMCPushComplete*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality = ccMulti,
  ] = object
    pinnedHandle*: ThreadHandle[MT, CC]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmuc[S, T, MT, ST, CC]

typestate SPMCPushContext[
  T,
  S: static int,
  MT: static int,
  ST: static DeallocationStrategy,
  CC: static PinScopeCardinality,
]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  defaults:
    ST:
      stEager
    CC:
      ccMulti
  states SPMCPushReady[T, S, MT, ST, CC],
    SPMCPushSegmentLoaded[T, S, MT, ST, CC],
    SPMCPushSegmentFull[T, S, MT, ST, CC],
    SPMCPushSlotReady[T, S, MT, ST, CC],
    SPMCPushComplete[T, S, MT, ST, CC]
  transitions:
    SPMCPushReady[T, S, MT, ST, CC] -> SPMCPushSegmentLoaded[T, S, MT, ST, CC]
    SPMCPushSegmentLoaded[T, S, MT, ST, CC] ->
      (SPMCPushSlotReady[T, S, MT, ST, CC] | SPMCPushSegmentFull[T, S, MT, ST, CC]) as
      SPMCSegmentCheck[T, S, MT, ST, CC]
    SPMCPushSegmentFull[T, S, MT, ST, CC] -> SPMCPushReady[T, S, MT, ST, CC]
    SPMCPushSlotReady[T, S, MT, ST, CC] -> SPMCPushComplete[T, S, MT, ST, CC]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality,
](
    pinned: sink Pinned[MT, CC], queue: ptr UnboundedSipmuc[S, T, MT, ST, CC]
): SPMCPushReady[T, S, MT, ST, CC] =
  ## Create push context from DEBRA's Pinned state.
  SPMCPushReady[T, S, MT, ST, CC](
    SPMCPushContext[T, S, MT, ST, CC](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from SPMCPushComplete for unpinning
proc extractPinned*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality,
](complete: sink SPMCPushComplete[T, S, MT, ST, CC]): Pinned[MT, CC] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT, CC](
    EpochGuardContext[MT, CC](
      handle: complete.pinnedHandle, epoch: complete.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality,
](
    ready: sink SPMCPushReady[T, S, MT, ST, CC]
): SPMCPushSegmentLoaded[T, S, MT, ST, CC] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = SPMCPushContext[T, S, MT, ST, CC](ready)
  let seg = ctx.queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  SPMCPushSegmentLoaded[T, S, MT, ST, CC](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Check full transition
proc checkFull*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality,
](
    loaded: sink SPMCPushSegmentLoaded[T, S, MT, ST, CC]
): SPMCSegmentCheck[T, S, MT, ST, CC] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull.
  if loaded.tail >= S:
    SPMCSegmentCheck[T, S, MT, ST, CC] ->
      SPMCPushSegmentFull[T, S, MT, ST, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )
  else:
    SPMCSegmentCheck[T, S, MT, ST, CC] ->
      SPMCPushSlotReady[T, S, MT, ST, CC](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: loaded.tail,
      )

# Allocate new segment transition
proc allocateNewSegment*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality,
](
    full: sink SPMCPushSegmentFull[T, S, MT, ST, CC], newSegment: ptr Segment[S, T]
): SPMCPushReady[T, S, MT, ST, CC] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  full.segment.next.store(newSegment, moRelease)
  full.queue.tailSegment = newSegment
  discard full.queue.segments.fetchAdd(1, moRelaxed)

  SPMCPushReady[T, S, MT, ST, CC](
    SPMCPushContext[T, S, MT, ST, CC](
      pinnedHandle: full.pinnedHandle, pinnedEpoch: full.pinnedEpoch, queue: full.queue
    )
  )

# Write item transition
proc writeItem*[
    T;
    S, MT: static int,
    ST: static DeallocationStrategy,
    CC: static PinScopeCardinality,
](
    slotReady: sink SPMCPushSlotReady[T, S, MT, ST, CC], item: T
): SPMCPushComplete[T, S, MT, ST, CC] {.transition.} =
  ## Write item to slot and publish.
  slotReady.segment.data[slotReady.slot] = item
  slotReady.segment.tail.store(slotReady.slot + 1, moRelease)
  discard slotReady.queue.itemCount.fetchAdd(1, moRelaxed)

  SPMCPushComplete[T, S, MT, ST, CC](
    pinnedHandle: slotReady.pinnedHandle,
    pinnedEpoch: slotReady.pinnedEpoch,
    queue: slotReady.queue,
  )
