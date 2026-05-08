## Typestate for unbounded MPSC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push with CAS coordination,
## bridges back. Multiple producers coordinate via CAS on tail pointer.

import ../atomic_dsl
import typestates
import debra

# `DeallocationStrategy` is declared canonically in `../unbounded_mupsic`,
# but production imports this typestate, so `from ../unbounded_mupsic import`
# would cycle. We declare a structurally-identical enum locally so the Base
# field type matches R11; the facade adds ord/sizeof static-asserts that
# guarantee layout equivalence between the two declarations.
type DeallocationStrategy* = enum
  ## Mirror of production's `DeallocationStrategy`. Layout equivalence is
  ## enforced by static-asserts in `../unbounded_mupsic`.
  Manual
  Eager

type
  # Segment type for MPSC - mirrors production at `unbounded_mupsic.nim:67-79`.
  # Field set, types, and {.align: CacheLineBytes.} pragmas mirror production
  # exactly so the facade's per-Segment-field offsetOf static-asserts pass.
  # Note: `head` is a plain `int` (single consumer, no atomic needed) but is
  # cache-line aligned so consumer head writes do not invalidate producers'
  # cached `tail` line.
  UMPSCSegment*[S: static int, T] = object
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr UMPSCSegment[S, T]]
    tail* {.align: CacheLineBytes.}: Atomic[int] # CAS coordination for producers
    head* {.align: CacheLineBytes.}: int
      # Consumer read position (single consumer, no atomic)
    committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
      # Track which slots are ready to read

  # Base queue type for MPSC. 9-field shape per design §2.2 (MPSC row).
  # Both head/tail Segment pointers are Atomic[ptr] per design §3 Item 2.
  # `strategy` is the `DeallocationStrategy` enum (NOT int) per R11.
  UnboundedMupsicBase*[S: static int, T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment* {.align: CacheLineBytes.}: Atomic[ptr UMPSCSegment[S, T]]
    tailSegment* {.align: CacheLineBytes.}: Atomic[ptr UMPSCSegment[S, T]]
    strategy*: DeallocationStrategy
    handle*: ThreadHandle[MaxThreads] # Consumer's handle (single consumer)
    itemCount*: Atomic[int]
    segments*: Atomic[int]
    producerCount*: Atomic[int]
    ownsManager*: bool

  # Base context - carries pinned state and queue pointer
  UMPSCPushContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  # States
  UMPSCPushReady*[T; S, MT: static int] = distinct UMPSCPushContext[T, S, MT]

  UMPSCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]
    tail*: int

  UMPSCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]

  UMPSCPushSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]
    slot*: int

  UMPSCPushItemWritten*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]
    slot*: int

  UMPSCPushComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

typestate UMPSCPushContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states UMPSCPushReady[T, S, MT],
    UMPSCPushSegmentLoaded[T, S, MT],
    UMPSCPushSegmentFull[T, S, MT],
    UMPSCPushSlotClaimed[T, S, MT],
    UMPSCPushItemWritten[T, S, MT],
    UMPSCPushComplete[T, S, MT]
  transitions:
    UMPSCPushReady[T, S, MT] -> UMPSCPushSegmentLoaded[T, S, MT]
    UMPSCPushSegmentLoaded[T, S, MT] ->
      (
        UMPSCPushSlotClaimed[T, S, MT] | UMPSCPushSegmentFull[T, S, MT] |
        UMPSCPushReady[T, S, MT]
      ) as UMPSCSlotClaimResult[T, S, MT]
    UMPSCPushSegmentFull[T, S, MT] -> UMPSCPushReady[T, S, MT]
    UMPSCPushSlotClaimed[T, S, MT] -> UMPSCPushItemWritten[T, S, MT]
    UMPSCPushItemWritten[T, S, MT] -> UMPSCPushComplete[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupsicBase[S, T, MT]
): UMPSCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state.
  UMPSCPushReady[T, S, MT](
    UMPSCPushContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from UMPSCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink UMPSCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink UMPSCPushReady[T, S, MT]
): UMPSCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position.
  let ctx = UMPSCPushContext[T, S, MT](ready)
  let seg = ctx.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  UMPSCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink UMPSCPushSegmentLoaded[T, S, MT]
): UMPSCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using CAS. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentFull: segment is full, need new segment
  ## - Ready: CAS failed, retry from beginning
  let tail = loaded.tail

  if tail >= S:
    return
      UMPSCSlotClaimResult[T, S, MT] ->
      UMPSCPushSegmentFull[T, S, MT](
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
      UMPSCSlotClaimResult[T, S, MT] ->
      UMPSCPushSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: tail,
      )
  else:
    # CAS failed - retry from beginning
    return
      UMPSCSlotClaimResult[T, S, MT] ->
      UMPSCPushReady[T, S, MT](
        UMPSCPushContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Handle segment full - allocate new segment.
#
# A1: We previously shipped two procs here (`allocateNewSegment` as a
# `.transition.` returning `UMPSCPushReady`, and `tryAllocateNewSegment`
# returning `(Ready, bool)` so callers could free the orphan on a lost
# race). Both did identical CAS work; the only delta was whether the
# `allocated` bit was returned. Keeping just the tuple form removes a
# redundant generic-instantiation per (T, S, MT, mm-mode) tuple. Callers
# that don't care about the bool simply `discard` the boolean tuple
# field. The typestate transition table still lists
# `UMPSCPushSegmentFull -> UMPSCPushReady` for documentation; the
# verifier (typestates 0.8.0, strictTransitions off) does not require an
# implementing `.transition.` proc for declared arrows.
proc tryAllocateNewSegment*[T; S, MT: static int](
    full: sink UMPSCPushSegmentFull[T, S, MT], newSegment: ptr UMPSCSegment[S, T]
): tuple[ready: UMPSCPushReady[T, S, MT], allocated: bool] =
  ## Try to link new segment using CAS.
  ## Returns (ready state, true if we allocated, false if someone else did).
  ## Callers that don't need the `allocated` bit (e.g., they always allocate
  ## a fresh segment up-front and don't care about freeing on lost races)
  ## destructure with `let (ready, _) = ...`.
  # Check if someone else already linked a segment
  let nextSeg = full.segment.next.load(moAcquire)
  if nextSeg != nil:
    # Someone else allocated, just advance
    var expectedSeg = full.segment
    discard
      full.queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
    return (
      UMPSCPushReady[T, S, MT](
        UMPSCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

  # Try to link our new segment
  var expectedNext: ptr UMPSCSegment[S, T] = nil
  if full.segment.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
    # Won the allocation race
    var expectedSeg = full.segment
    discard full.queue.tailSegment.compareExchange(
      expectedSeg, newSegment, moRelease, moRelaxed
    )
    discard full.queue.segments.fetchAdd(1, moRelaxed)
    return (
      UMPSCPushReady[T, S, MT](
        UMPSCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      true,
    )
  else:
    # Lost race, caller should free newSegment
    # Try to advance using whatever segment won
    let winnerSeg = full.segment.next.load(moAcquire)
    if winnerSeg != nil:
      var expectedSeg = full.segment
      discard full.queue.tailSegment.compareExchange(
        expectedSeg, winnerSeg, moRelease, moRelaxed
      )
    return (
      UMPSCPushReady[T, S, MT](
        UMPSCPushContext[T, S, MT](
          pinnedHandle: full.pinnedHandle,
          pinnedEpoch: full.pinnedEpoch,
          queue: full.queue,
        )
      ),
      false,
    )

# Write item to claimed slot
proc writeItem*[T; S, MT: static int](
    claimed: sink UMPSCPushSlotClaimed[T, S, MT], item: T
): UMPSCPushItemWritten[T, S, MT] {.transition.} =
  ## Write item to slot.
  claimed.segment.data[claimed.slot] = item

  UMPSCPushItemWritten[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot,
  )

# Mark slot as committed
proc markCommitted*[T; S, MT: static int](
    written: sink UMPSCPushItemWritten[T, S, MT]
): UMPSCPushComplete[T, S, MT] {.transition.} =
  ## Mark slot as committed.
  written.segment.committed[written.slot].store(true, moRelease)
  discard written.queue.itemCount.fetchAdd(1, moRelaxed)

  UMPSCPushComplete[T, S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue,
  )
