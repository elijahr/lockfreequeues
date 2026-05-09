## Typestate for unbounded MPMC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push with CAS coordination
## and committed flags, bridges back. Multiple producers coordinate via CAS on
## tail.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded MPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

# `DeallocationStrategy` is declared canonically in `../unbounded_mupmuc`,
# but production imports this typestate, so `from ../unbounded_mupmuc import`
# would cycle. We declare a structurally-identical enum locally so the Base
# field type matches R11; the facade adds ord/sizeof static-asserts that
# guarantee layout equivalence between the two declarations.
type DeallocationStrategy* = enum
  ## Mirror of production's `DeallocationStrategy`. Layout equivalence is
  ## enforced by static-asserts in `../unbounded_mupmuc`.
  Manual
  Eager

type
  # Segment type for MPMC - mirrors production at `unbounded_mupmuc.nim:65-73`.
  # Field set, types, and {.align: CacheLineBytes.} pragmas mirror production
  # exactly so the facade's per-Segment-field offsetOf static-asserts pass.
  # MPMC has BOTH `committed` array (multi-producer publication signal) AND
  # `prevConsumerIdx` (consumer-vs-consumer CAS coordination).
  UMPMCSegment*[S: static int, T] = object
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr UMPMCSegment[S, T]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for producers
    prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for consumers
    committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
      # Track which slots are ready to read

  # Base queue type for MPMC. 9-field shape per design §2.2 (MPMC row).
  # Both head/tail Segment pointers are Atomic[ptr] per design §3 Item 2
  # (headSegment for consumer-vs-consumer CAS; tailSegment for
  # producer-vs-producer CAS). The `{.align: CacheLineBytes.}` pragmas
  # mirror production at `unbounded_mupmuc.nim:82,84` so producer and
  # consumer writes do not share a cache line.
  # `strategy` is the `DeallocationStrategy` enum (NOT int) per R11.
  UnboundedMupmucBase*[S: static int, T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment* {.align: CacheLineBytes.}: Atomic[ptr UMPMCSegment[S, T]]
    tailSegment* {.align: CacheLineBytes.}: Atomic[ptr UMPMCSegment[S, T]]
    strategy*: DeallocationStrategy
    itemCount*: Atomic[int]
    segments*: Atomic[int]
    producerCount*: Atomic[int]
    consumerCount*: Atomic[int]
    ownsManager*: bool

  # Base context - carries pinned state and queue pointer
  UMPMCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  # States (U-prefix per overlay #5: typestates 0.8.0 registry collision
  # with bounded MPMC* graph).
  UMPMCPushReady*[T; S, MT: static int] = distinct UMPMCPushContext[T, S, MT]

  UMPMCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    tail*: int

  UMPMCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]

  UMPMCPushSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    slot*: int

  UMPMCPushItemWritten*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    slot*: int

  UMPMCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

typestate UMPMCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states UMPMCPushReady[T, S, MT],
    UMPMCPushSegmentLoaded[T, S, MT],
    UMPMCPushSegmentFull[T, S, MT],
    UMPMCPushSlotClaimed[T, S, MT],
    UMPMCPushItemWritten[T, S, MT],
    UMPMCPushComplete[T, S, MT]
  transitions:
    UMPMCPushReady[T, S, MT] -> UMPMCPushSegmentLoaded[T, S, MT]
    UMPMCPushSegmentLoaded[T, S, MT] ->
      (
        UMPMCPushSlotClaimed[T, S, MT] | UMPMCPushSegmentFull[T, S, MT] |
        UMPMCPushReady[T, S, MT]
      ) as UMPMCSlotClaimResult[T, S, MT]
    UMPMCPushSegmentFull[T, S, MT] -> UMPMCPushReady[T, S, MT]
    UMPMCPushSlotClaimed[T, S, MT] -> UMPMCPushItemWritten[T, S, MT]
    UMPMCPushItemWritten[T, S, MT] -> UMPMCPushComplete[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupmucBase[S, T, MT]
): UMPMCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  UMPMCPushReady[T, S, MT](
    UMPMCPushContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from UMPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink UMPMCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink UMPMCPushReady[T, S, MT]
): UMPMCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  ## Mirrors production memory ordering at `unbounded_mupmuc.nim:270-271`:
  ## acquire-load the tailSegment (so a concurrent producer's release-store
  ## on `tailSegment.compareExchange` happens-before this load), then
  ## acquire-load `seg.tail` to pair with peer producers' release-stores
  ## from the slot CAS (success edge writes `tail.store(moRelease)` is the
  ## CAS itself; the compareExchange's success memory order is moAcquire).
  let ctx = UMPMCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  UMPMCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink UMPMCPushSegmentLoaded[T, S, MT]
): UMPMCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  let tail = loaded.tail

  if tail >= S:
    return
      UMPMCSlotClaimResult[T, S, MT] ->
      UMPMCPushSegmentFull[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Try CAS
  var expected = tail
  if loaded.segment.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
    # Won the slot
    return
      UMPMCSlotClaimResult[T, S, MT] ->
      UMPMCPushSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: tail,
      )
  else:
    # CAS failed - retry from beginning
    return
      UMPMCSlotClaimResult[T, S, MT] ->
      UMPMCPushReady[T, S, MT](
        UMPMCPushContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Handle segment full - allocate new segment.
#
# A1: We previously shipped two procs here (`allocateNewSegment` as a
# `.transition.` returning `UMPMCPushReady`, and `tryAllocateNewSegment`
# returning `(Ready, bool)` so callers could free the orphan on a lost
# race). Both did identical CAS work; the only delta was whether the
# `allocated` bit was returned. Keeping just the tuple form removes a
# redundant generic-instantiation per (T, S, MT, mm-mode) tuple. The
# typestate transition table still lists `UMPMCPushSegmentFull ->
# UMPMCPushReady` for documentation; the verifier (typestates 0.8.0,
# strictTransitions off) does not require an implementing `.transition.`
# proc for declared arrows.
proc tryAllocateNewSegment*[T; S, MT: static int](
    full: sink UMPMCPushSegmentFull[T, S, MT], newSegment: ptr UMPMCSegment[S, T]
): tuple[ready: UMPMCPushReady[T, S, MT], allocated: bool] =
  ## Try to link new segment using CAS.
  ## Returns (ready state, true if we allocated, false if someone else did).
  ## Callers that don't need the `allocated` bit destructure with
  ## `let (ready, _) = ...`.
  ## Mirrors production at `unbounded_mupmuc.nim:276-304`.
  # Check if someone else already linked a segment
  let nextSeg = full.segment.next.load(moAcquire)
  if nextSeg != nil:
    # Someone else allocated, just advance tailSegment (best effort —
    # compareExchange may fail because another producer already advanced).
    var expectedSeg = full.segment
    discard
      full.queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
    return (
      UMPMCPushReady[T, S, MT](
        UMPMCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

  # Try to link our new segment via `seg.next` CAS
  var expectedNext: ptr UMPMCSegment[S, T] = nil
  if full.segment.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
    # Won the allocation race - advance tailSegment (best effort) and
    # increment segments counter.
    var expectedSeg = full.segment
    discard full.queue.tailSegment.compareExchange(
      expectedSeg, newSegment, moRelease, moRelaxed
    )
    discard full.queue.segments.fetchAdd(1, moRelaxed)
    return (
      UMPMCPushReady[T, S, MT](
        UMPMCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      true,
    )
  else:
    # Lost race - caller should free newSegment. Try to advance using
    # whatever segment won.
    let winnerSeg = full.segment.next.load(moAcquire)
    if winnerSeg != nil:
      var expectedSeg = full.segment
      discard full.queue.tailSegment.compareExchange(
        expectedSeg, winnerSeg, moRelease, moRelaxed
      )
    return (
      UMPMCPushReady[T, S, MT](
        UMPMCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

# Write item to claimed slot
proc writeItem*[T; S, MT: static int](
    claimed: sink UMPMCPushSlotClaimed[T, S, MT], item: T
): UMPMCPushItemWritten[T, S, MT] {.transition.} =
  ## Write item to slot. The `committed[slot]` flag stays false until
  ## `markCommitted` publishes via release-store; consumers acquire-load
  ## the committed flag before reading `data[slot]`.
  claimed.segment.data[claimed.slot] = item

  UMPMCPushItemWritten[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot,
  )

# Mark slot as committed
proc markCommitted*[T; S, MT: static int](
    written: sink UMPMCPushItemWritten[T, S, MT]
): UMPMCPushComplete[T, S, MT] {.transition.} =
  ## Publish slot via `committed[slot].store(true, moRelease)`. Consumers
  ## acquire-load this flag in `tryClaimSlot` (and again in `readItem`)
  ## before reading `data[slot]`, establishing happens-before with the
  ## `writeItem` store above.
  written.segment.committed[written.slot].store(true, moRelease)
  discard written.queue.itemCount.fetchAdd(1, moRelaxed)

  UMPMCPushComplete[T, S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue,
  )
