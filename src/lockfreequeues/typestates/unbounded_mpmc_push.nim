## Typestate for unbounded MPMC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push with CAS coordination
## on `seg.tail` (multi-producer slot reservation) plus the LCRQ per-slot
## tri-state `cellState[]` (Task 11 / Task 14 migration; replaces the prior
## per-slot `committed[]` flag). Multiple producers coordinate via CAS on
## `seg.tail` to reserve slots, then publish via per-slot CAS on
## `cellState[slot]` (CellEmpty -> CellFilled). Closure-CAS-on-empty by
## consumers can cause publish-CAS failure, triggering Shape A retry and
## eventual segment-closure escalation.
##
## C-1 asymmetry vs SPMC: MPMC's `tryClaimSlot` ALREADY performs the
## reservation CAS on `seg.tail` (multi-producer slot ownership), so the
## resulting `UMPMCPushSlotClaimed` carries the reserved `slot: int`. The
## subsequent `writeItem` consumes that slot directly — there is NO
## entry `fetchAdd(seg.tail)` at the top of MPMC writeItem (unlike SPMC
## writeItem at `unbounded_spmc_push.nim:321`, which fetchAdds because
## SPMC's `USPMCPushSlotReady` carries no slot field). Shape A retry on
## publish-CAS failure DOES use `seg.tail.fetchAdd(1, moRelaxed)` to
## obtain a fresh slot for the retry attempt — see writeItem body.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded MPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

const
  ## LCRQ per-slot tri-state cell encoding (Task 11, design §3 D1).
  ## CellEmpty matches Nim's default-init of array[S, Atomic[uint8]], so
  ## Segment.new does not need an explicit init loop for cellState.
  ##
  ## CRITICAL-1: this block is a literal re-declaration of the SPMC
  ## `unbounded_spmc_push.nim:22-28` block so MPMC's compile remains
  ## independent of SPMC (no re-export coupling). Layout equivalence
  ## across the two declarations is byte-for-byte identical (same value
  ## bindings on the same `uint8` storage).
  CellEmpty*: uint8 = 0
  CellFilled*: uint8 = 1
  CellClosed*: uint8 = 2

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
  # Segment type for MPMC - mirrors production at `unbounded_mupmuc.nim:74-83`.
  # Field set, types, and {.align: CacheLineBytes.} pragmas mirror production
  # exactly so the facade's per-Segment-field offsetOf static-asserts pass.
  # MPMC has BOTH the per-slot `cellState` array (LCRQ tri-state replacing
  # v4.0's `committed[]` bool array) AND `consumerHead` (consumer-vs-consumer
  # fetchAdd coordination). The segment-level `closed` flag (LCRQ
  # starvation-escalation) is appended after cellState.
  UMPMCSegment*[S: static int, T] = object
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr UMPMCSegment[S, T]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for producers (reserved-slot index)
    consumerHead* {.align: CacheLineBytes.}: Atomic[int]
      # fetchAdd coordination for consumers (next-claimable slot)
    cellState* {.align: CacheLineBytes.}: array[S, Atomic[uint8]]
      # LCRQ per-slot tri-state (Task 11; replaces former `committed`).
    closed* {.align: CacheLineBytes.}: Atomic[bool]
      # LCRQ segment-level starvation-escalation flag (Task 11).

  # Base queue type for MPMC. 9-field shape per design §2.2 (MPMC row).
  # Both head/tail Segment pointers are Atomic[ptr] per design §3 Item 2
  # (headSegment for consumer-vs-consumer CAS; tailSegment for
  # producer-vs-producer CAS). The `{.align: CacheLineBytes.}` pragmas
  # mirror production at `unbounded_mupmuc.nim:92,94` so producer and
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
  #
  # Task 14 / C4 propagation: every push state carries a `pendingItem: T`
  # field so the item-to-publish travels with the typestate from
  # `startPush` through to `writeItem` (instead of being passed as a
  # separate parameter to `writeItem`). This keeps the source expression
  # evaluated exactly once per push, regardless of retry rounds.
  #
  # C-1 asymmetry vs SPMC: `UMPMCPushSlotClaimed` RETAINS the `slot: int`
  # field. MPMC's `tryClaimSlot` performs the reservation CAS on
  # `seg.tail` (multi-producer slot ownership), so the reserved slot is
  # known at typestate transition time. SPMC's `USPMCPushSlotReady` has
  # no slot field because SPMC's writeItem entry-fetchAdds the slot
  # (single producer, no reservation CAS).
  UMPMCPushReady*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    pendingItem*: T

  UMPMCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    tail*: int
    pendingItem*: T

  UMPMCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    pendingItem*: T

  UMPMCPushSlotClaimed*[T; S, MT: static int] = object
    ## MPMC `tryClaimSlot`'s reservation CAS on `seg.tail` succeeded. The
    ## reserved `slot` index is carried forward (C-1 asymmetry vs SPMC's
    ## `USPMCPushSlotReady`, which carries no slot — SPMC's writeItem
    ## entry-fetchAdds). `writeItem` consumes this state, publishes via
    ## per-slot publish-CAS, and on failure performs Shape A retry via
    ## `seg.tail.fetchAdd(1, moRelaxed)`.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    slot*: int
    pendingItem*: T

  UMPMCPushSegmentClosed*[T; S, MT: static int] = object
    ## Task 11 LCRQ: producer's publish-CAS lost to a consumer's
    ## close-CAS (or starvation threshold reached), and we T&S'd
    ## `seg.closed` to escalate to segment closure. The closeSegmentDone
    ## verb bridges this to `UMPMCPushSegmentFull` so the existing
    ## allocate-and-retry path can rotate to a fresh segment.
    ##
    ## C-1 asymmetry note: `slot: int` is NOT carried here. The new
    ## segment issued via the closure-escalation path will obtain its
    ## own slot through `tryClaimSlot`'s reservation CAS; the prior slot
    ## belonged to the closed (retired) segment and has no meaning on
    ## the successor.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr UMPMCSegment[S, T]
    pendingItem*: T

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
    UMPMCPushSegmentClosed[T, S, MT],
    UMPMCPushSlotClaimed[T, S, MT],
    UMPMCPushComplete[T, S, MT]
  transitions:
    UMPMCPushReady[T, S, MT] -> UMPMCPushSegmentLoaded[T, S, MT]
    UMPMCPushSegmentLoaded[T, S, MT] ->
      (
        UMPMCPushSlotClaimed[T, S, MT] | UMPMCPushSegmentFull[T, S, MT] |
        UMPMCPushReady[T, S, MT]
      ) as UMPMCSlotClaimResult[T, S, MT]
    UMPMCPushSegmentFull[T, S, MT] -> UMPMCPushReady[T, S, MT]
    UMPMCPushSegmentClosed[T, S, MT] -> UMPMCPushSegmentFull[T, S, MT]
    UMPMCPushSlotClaimed[T, S, MT] ->
      (
        UMPMCPushComplete[T, S, MT] | UMPMCPushSegmentLoaded[T, S, MT] |
        UMPMCPushSegmentClosed[T, S, MT]
      ) as UMPMCPushCommitResult[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state.
#
# Task 14 / C4 fix: `pendingItem: sink T` enters the typestate chain here
# and is threaded through every state until `writeItem` consumes it. This
# keeps the source expression evaluated exactly once (per push) regardless
# of how many SegmentFull / SegmentClosed / publish-CAS-retry rounds occur.
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT],
    queue: ptr UnboundedMupmucBase[S, T, MT],
    pendingItem: sink T,
): UMPMCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state, carrying the item to
  ## publish into the typestate chain.
  UMPMCPushReady[T, S, MT](
    pinnedHandle: pinned.handle,
    pinnedEpoch: pinned.epoch,
    queue: queue,
    pendingItem: pendingItem,
  )

# Extract Pinned state from UMPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink UMPMCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Extract Pinned state from UMPMCPushSegmentClosed for unpinning.
#
# Task 14: SegmentClosed is a non-terminal state in the happy path (the
# producer normally transitions to SegmentFull via closeSegmentDone, then
# allocates a fresh segment and retries). However the caller may choose
# to abandon the push — for example, if the close is observed during a
# shutdown drain — in which case it needs to recover the Pinned[MT]
# handle to call `unpin`. The pendingItem is dropped on the floor when
# this proc consumes the state; that is intentional and documented in
# the facade-level abort path.
proc extractPinned*[T; S, MT: static int](
    closed: sink UMPMCPushSegmentClosed[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning from a SegmentClosed
  ## state (caller-initiated abort path). The pendingItem is dropped.
  Pinned[MT](
    EpochGuardContext[MT](handle: closed.pinnedHandle, epoch: closed.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink UMPMCPushReady[T, S, MT]
): UMPMCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position, threading `pendingItem`
  ## forward into SegmentLoaded.
  ## Mirrors production memory ordering at `unbounded_mupmuc.nim:344-355`:
  ## acquire-load the tailSegment (so a concurrent producer's release-store
  ## on `tailSegment.compareExchange` happens-before this load), then
  ## acquire-load `seg.tail` to pair with peer producers' release-stores
  ## from the slot CAS.
  let seg = ready.queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  UMPMCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ready.pinnedHandle,
    pinnedEpoch: ready.pinnedEpoch,
    queue: ready.queue,
    segment: seg,
    tail: tail,
    pendingItem: ready.pendingItem,
  )

# Try to claim slot with reservation CAS on seg.tail.
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink UMPMCPushSegmentLoaded[T, S, MT]
): UMPMCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using reservation CAS on `seg.tail`. Returns:
  ## - SlotClaimed: CAS succeeded, slot is reserved (carries the reserved
  ##   index in `slot` per C-1 asymmetry).
  ## - SegmentFull: segment is full (tail >= S), need new segment.
  ## - Ready: CAS failed (producer-vs-producer race), retry from beginning.
  ##
  ## Threads `pendingItem` forward into every branch (I-5 fix: the Ready
  ## arm must propagate pendingItem so the producer-vs-producer race loser
  ## preserves its carried item across the re-claim cycle).
  let tail = loaded.tail

  if tail >= S:
    return
      UMPMCSlotClaimResult[T, S, MT] ->
      UMPMCPushSegmentFull[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        pendingItem: loaded.pendingItem,
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
        pendingItem: loaded.pendingItem,
      )
  else:
    # CAS failed - retry from beginning. I-5: propagate pendingItem into
    # the rebuilt Ready so the producer-vs-producer race-loser preserves
    # its carried item across the re-claim cycle. Without this, MPMC
    # under contention would lose the pendingItem (missed item under
    # R7 stress).
    return
      UMPMCSlotClaimResult[T, S, MT] ->
      UMPMCPushReady[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        pendingItem: loaded.pendingItem,
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
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue,
        pendingItem: full.pendingItem,
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
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue,
        pendingItem: full.pendingItem,
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
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue,
        pendingItem: full.pendingItem,
      ),
      false,
    )

# Close-observed transition.
#
# Task 14: mirror of SPMC `closeSegmentDone` at `unbounded_spmc_push.nim:291-303`.
# Bridges SegmentClosed back into the SegmentFull lane so the existing
# allocate-and-retry path can rotate to a fresh segment via
# `tryAllocateNewSegment`. The transition does not mutate cellState or
# closed here — those mutations are the responsibility of `writeItem`'s
# closure-escalation T&S on `seg.closed`.
proc closeSegmentDone*[T; S, MT: static int](
    closed: sink UMPMCPushSegmentClosed[T, S, MT]
): UMPMCPushSegmentFull[T, S, MT] {.transition.} =
  ## Bridge SegmentClosed back into the SegmentFull lane so the existing
  ## allocate-and-retry path can rotate to a fresh segment. Threads
  ## `pendingItem` forward to keep the source expression evaluated once.
  UMPMCPushSegmentFull[T, S, MT](
    pinnedHandle: closed.pinnedHandle,
    pinnedEpoch: closed.pinnedEpoch,
    queue: closed.queue,
    segment: closed.segment,
    pendingItem: closed.pendingItem,
  )

# Write item transition (Task 11 / Task 14 LCRQ).
#
# C-1 asymmetry vs SPMC: NO entry fetchAdd on seg.tail. The initial slot
# comes from `claimed.slot` (set by `tryClaimSlot`'s reservation CAS via
# MPMC's multi-producer ownership protocol). Shape A retry on publish-CAS
# failure obtains fresh slots via `seg.tail.fetchAdd(1, moRelaxed)` —
# this is the ONLY tail.fetchAdd inside writeItem.
#
# Audit checklist (Task 14 acceptance, mirror SPMC writeItem):
# - StarvingThreshold = S declared INSIDE the proc (I2).
# - doAssert closureRetryCount <= StarvingThreshold INSIDE the increment
#   branch, BEFORE the threshold compare (I4).
# - Shape A retry: seg.tail.fetchAdd(1, moRelaxed) on publish-CAS failure (C5).
# - pendingItem moved on every escalation branch (C4).
# - NO entry fetchAdd (C-1).
# - UMPMCPushSlotClaimed carries slot: int (C-1).
proc writeItem*[T; S, MT: static int](
    claimed: sink UMPMCPushSlotClaimed[T, S, MT]
): UMPMCPushCommitResult[T, S, MT] {.transition.} =
  ## Publish-CAS on `seg.cellState[claimed.slot]` (CellEmpty -> CellFilled).
  ## On CAS failure (cell observed as CellClosed by consumer's close-CAS),
  ## Shape A retry: `seg.tail.fetchAdd(1, moRelaxed)` to obtain a fresh
  ## slot, re-attempt publish-CAS. Bounded by StarvingThreshold = S per
  ## design §3 D5 + §8. On threshold reached or fresh slot >= S, T&S
  ## `seg.closed` and escalate to `UMPMCPushSegmentClosed`.
  ##
  ## C-1 asymmetry: the initial slot comes from `claimed.slot` (the
  ## reservation CAS in `tryClaimSlot`). MPMC writeItem has NO entry
  ## fetchAdd, unlike SPMC writeItem at `unbounded_spmc_push.nim:321`.
  ## The fetchAdd inside the retry loop below is Shape A retry, not an
  ## entry fetchAdd.
  const StarvingThreshold = S  # I2: per-call const bound to generic S
  let seg = claimed.segment
  var pending = claimed.pendingItem  # sink-bound, move-friendly
  var myTailSlot = claimed.slot  # C-1: initial slot from reservation CAS
  var closureRetryCount = 0
  while true:
    # Publish-CAS attempt.
    # Write the value into the cell with `move` so types lacking copy
    # hooks (e.g. `MoveOnly`) compile. The publish-CAS release-fence
    # carries the data write to consumers (design brief §2.4), and the
    # cell value is private to the producer until the CAS wins. On
    # CAS-failure the cell is `CellClosed` (written by a consumer's
    # close-CAS); we recover the value back into `pending` via
    # `move(seg.data[myTailSlot])` immediately after the CAS-fail check.
    #
    # MPMC soundness of recovery: the consumer's
    # `consumerHead.fetchAdd(1, moAcquire)` returns a UNIQUE `mySlot`
    # per consumer (design §8 single-fetchAdd uniqueness; §7.1 E2
    # cell-close edge), so no peer consumer can
    # close OUR slot; the segment-closure T&S targets `seg.closed`
    # (segment-level bool), not `cellState[i]`. Therefore, if our
    # publish-CAS fails, the observed state MUST be `CellClosed`
    # written by the over-claiming consumer paired with our exact
    # `myTailSlot`. Recovery leaves `pending` valid for the next
    # iteration's data-write and the escalation-branch transitions.
    seg.data[myTailSlot] = move(pending)
    var expected: uint8 = CellEmpty
    let publishWon = seg.cellState[myTailSlot].compareExchange(
        expected, CellFilled, moAcquireRelease, moAcquire)
    if publishWon:
      discard claimed.queue.itemCount.fetchAdd(1, moRelaxed)
      return UMPMCPushCommitResult[T, S, MT] ->
        UMPMCPushComplete[T, S, MT](
          pinnedHandle: claimed.pinnedHandle,
          pinnedEpoch: claimed.pinnedEpoch,
          queue: claimed.queue,
        )
    # CAS failure: cell must be CellClosed. CellFilled is impossible —
    # each producer's reserved slot (via seg.tail CAS / Shape A
    # fetchAdd) is unique; no peer producer can have published our
    # slot.
    doAssert expected == CellClosed,
      "MPMC writeItem: cell observed unexpected state on publish-CAS failure"
    # Recover `pending` from the just-failed cell. The cell is
    # `CellClosed`; the consumer's close-CAS-on-empty (introduced by
    # Task 16) writes CellClosed at `unbounded_mpmc_pop.nim` tryClaimSlot.
    # The producer-side recovery leaves `pending` valid for the next
    # loop iteration's data-write AND for the escalation-branch
    # transitions below.
    pending = move(seg.data[myTailSlot])
    # I4: assert bound INSIDE increment branch, BEFORE threshold compare.
    closureRetryCount += 1
    doAssert closureRetryCount <= StarvingThreshold,
      "MPMC writeItem: closureRetryCount exceeded StarvingThreshold = S (design §8)"
    let observedTail = seg.tail.load(moRelaxed)
    if closureRetryCount >= StarvingThreshold or observedTail >= S:
      # Starvation: T&S seg.closed and transition to SegmentClosed.
      var expectedClosed: bool = false
      discard seg.closed.compareExchange(
          expectedClosed, true, moAcquireRelease, moAcquire)
      return UMPMCPushCommitResult[T, S, MT] ->
        UMPMCPushSegmentClosed[T, S, MT](
          pinnedHandle: claimed.pinnedHandle,
          pinnedEpoch: claimed.pinnedEpoch,
          queue: claimed.queue,
          segment: seg,
          pendingItem: move(pending),
        )
    # C5 Shape A retry: fetchAdd seg.tail, adopt new myTailSlot. This is
    # the ONLY fetchAdd on seg.tail inside writeItem; the initial slot
    # came from `claimed.slot` (the reservation CAS in tryClaimSlot).
    let nextSlot = seg.tail.fetchAdd(1, moRelaxed)
    if nextSlot >= S:
      # Segment saturated mid-retry; T&S and escalate.
      var expectedClosed: bool = false
      discard seg.closed.compareExchange(
          expectedClosed, true, moAcquireRelease, moAcquire)
      return UMPMCPushCommitResult[T, S, MT] ->
        UMPMCPushSegmentClosed[T, S, MT](
          pinnedHandle: claimed.pinnedHandle,
          pinnedEpoch: claimed.pinnedEpoch,
          queue: claimed.queue,
          segment: seg,
          pendingItem: move(pending),
        )
    myTailSlot = nextSlot
    # Loop to top: publish-CAS at new slot.
