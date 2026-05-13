## Typestate for unbounded SPMC push operations.
##
## SPMC has a single producer (no CAS coordination needed for push) but
## multiple consumers; producer publishes via `tail.store(moRelease)` and
## consumers spin on `prevConsumerIdx` CAS in the pop typestate. There is
## NO `committed` array on SPMC segments — the single producer's release
## store is the publication signal.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded SPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

const
  ## LCRQ per-slot tri-state cell encoding (Task 11, design §3 D1).
  ## CellEmpty matches Nim's default-init of array[S, Atomic[uint8]], so
  ## Segment.new does not need an explicit init loop for cellState.
  CellEmpty*: uint8 = 0
  CellFilled*: uint8 = 1
  CellClosed*: uint8 = 2

# `DeallocationStrategy` is declared canonically in `../unbounded_sipmuc`,
# but production imports this typestate, so `from ../unbounded_sipmuc import`
# would cycle. We declare a structurally-identical enum locally so the Base
# field type matches R11; the facade adds ord/sizeof static-asserts that
# guarantee layout equivalence between the two declarations.
type DeallocationStrategy* = enum
  ## Mirror of production's `DeallocationStrategy`. Layout equivalence is
  ## enforced by static-asserts in `../unbounded_sipmuc`.
  Manual
  Eager

type
  # Segment type for SPMC - mirrors production at `unbounded_sipmuc.nim:69-75`.
  # Field set, types, and {.align: CacheLineBytes.} pragmas mirror production
  # exactly so the facade's per-Segment-field offsetOf static-asserts pass.
  # SPMC has NO `committed` array — the single producer publishes via
  # `tail.store(moRelease)`; consumers coordinate via `prevConsumerIdx` CAS.
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
      # Producer write position within segment
    prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for consumers

  # Base queue type for SPMC. 8-field shape per design §2.2 (SPMC row,
  # post-Item-5 dead-array removal). `headSegment` is `Atomic[ptr]`
  # (consumer-side advance under CAS); `tailSegment` is plain `ptr` per
  # design §3 Item 2 (single producer, no atomicity required for stores).
  # The `{.align: CacheLineBytes.}` pragma on `tailSegment` mirrors
  # production at `unbounded_sipmuc.nim:86` so producer writes do not
  # share a cache line with the consumer-mutated `headSegment`.
  # `strategy` is the `DeallocationStrategy` enum (NOT int) per R11.
  UnboundedSipmucBase*[S: static int, T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
    tailSegment* {.align: CacheLineBytes.}: ptr Segment[S, T]
    strategy*: DeallocationStrategy
    itemCount*: Atomic[int]
    segments*: Atomic[int]
    consumerCount*: Atomic[int]
    ownsManager*: bool

  # Base context - carries pinned state and queue pointer
  USPMCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  # States (U-prefix per overlay #5: typestates 0.8.0 registry collision
  # with bounded SPMC* graph).
  USPMCPushReady*[T; S, MT: static int] = distinct USPMCPushContext[T, S, MT]

  USPMCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    tail*: int

  USPMCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]

  USPMCPushSlotReady*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    slot*: int

  USPMCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

typestate USPMCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states USPMCPushReady[T, S, MT],
    USPMCPushSegmentLoaded[T, S, MT],
    USPMCPushSegmentFull[T, S, MT],
    USPMCPushSlotReady[T, S, MT],
    USPMCPushComplete[T, S, MT]
  transitions:
    USPMCPushReady[T, S, MT] -> USPMCPushSegmentLoaded[T, S, MT]
    USPMCPushSegmentLoaded[T, S, MT] ->
      (USPMCPushSlotReady[T, S, MT] | USPMCPushSegmentFull[T, S, MT]) as
      USPMCSegmentCheck[T, S, MT]
    USPMCPushSegmentFull[T, S, MT] -> USPMCPushReady[T, S, MT]
    USPMCPushSlotReady[T, S, MT] -> USPMCPushComplete[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedSipmucBase[S, T, MT]
): USPMCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  USPMCPushReady[T, S, MT](
    USPMCPushContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from USPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink USPMCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink USPMCPushReady[T, S, MT]
): USPMCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  ## Mirrors production memory ordering: SPMC has a single producer that
  ## owns `tailSegment` (plain ptr), so a relaxed-equivalent direct read
  ## is sufficient. The current segment's `tail` is also producer-only
  ## except for consumer reads that pair with `tail.store(moRelease)`.
  let ctx = USPMCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  USPMCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Check full transition
proc checkFull*[T; S, MT: static int](
    loaded: sink USPMCPushSegmentLoaded[T, S, MT]
): USPMCSegmentCheck[T, S, MT] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull.
  if loaded.tail >= S:
    USPMCSegmentCheck[T, S, MT] ->
      USPMCPushSegmentFull[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )
  else:
    USPMCSegmentCheck[T, S, MT] ->
      USPMCPushSlotReady[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: loaded.tail,
      )

# Allocate new segment transition
#
# A1: Single producer in SPMC means there is no allocation race; the
# `tryAllocateNewSegment` tuple form (used by MPSC for CAS-loss handling)
# is unnecessary here. We keep ONLY the single-form `allocateNewSegment`
# transition. No A1 redundancy to drop.
proc allocateNewSegment*[T; S, MT: static int](
    full: sink USPMCPushSegmentFull[T, S, MT], newSegment: ptr Segment[S, T]
): USPMCPushReady[T, S, MT] {.transition.} =
  ## Link new segment and return to Ready state to retry.
  ## Mirrors production memory ordering: publish the new segment via
  ## `seg.next` (release) so a concurrent consumer that observes the
  ## new next pointer also sees the segment's initialized fields. The
  ## `tailSegment` advance is a plain pointer write — single producer,
  ## no readers other than this producer.
  full.segment.next.store(newSegment, moRelease)
  full.queue.tailSegment = newSegment
  discard full.queue.segments.fetchAdd(1, moRelaxed)

  USPMCPushReady[T, S, MT](
    USPMCPushContext[T, S, MT](
      pinnedHandle: full.pinnedHandle, pinnedEpoch: full.pinnedEpoch, queue: full.queue
    )
  )

# Write item transition
proc writeItem*[T; S, MT: static int](
    slotReady: sink USPMCPushSlotReady[T, S, MT], item: T
): USPMCPushComplete[T, S, MT] {.transition.} =
  ## Write item to slot and publish via `tail.store(moRelease)`.
  ## SPMC has no `committed` array — the release store on `tail` is the
  ## publication signal that consumers acquire-load before reading.
  slotReady.segment.data[slotReady.slot] = item
  slotReady.segment.tail.store(slotReady.slot + 1, moRelease)
  discard slotReady.queue.itemCount.fetchAdd(1, moRelaxed)

  USPMCPushComplete[T, S, MT](
    pinnedHandle: slotReady.pinnedHandle,
    pinnedEpoch: slotReady.pinnedEpoch,
    queue: slotReady.queue,
  )
