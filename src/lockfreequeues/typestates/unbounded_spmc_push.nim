## Typestate for unbounded SPMC push operations.
##
## SPMC has a single producer (no CAS coordination needed for push) but
## multiple consumers; producer publishes via `tail.store(moRelease)` and
## consumers spin on `consumerHead` CAS in the pop typestate. There is
## NO `committed` array on SPMC segments — the single producer's release
## store is the publication signal.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded SPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

when defined(awaitingTailTestHook):
  # Test-only: gated synchronization channels for the awaitingTail-strand
  # regression test. See `../private/awaiting_tail_test_hook.nim` for the
  # purity contract. DO NOT enable in production builds.
  import ../private/awaiting_tail_test_hook

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
  # `tail.store(moRelease)`; consumers coordinate via `consumerHead` CAS.
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
      # Producer write position within segment
    consumerHead* {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for consumers
    cellState* {.align: CacheLineBytes.}: array[S, Atomic[uint8]]
      # LCRQ per-slot tri-state (CellEmpty/CellFilled/CellClosed); Task 11 C1.
    closed* {.align: CacheLineBytes.}: Atomic[bool]
      # Segment-level closed flag (LCRQ adaptation); Task 11 C1.

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
  #
  # Task 6 / C-1 fix: every push state carries a `pendingItem: T` field so
  # the item-to-publish travels with the typestate from `startPush` through
  # to `writeItem` (instead of being passed as a separate parameter to the
  # terminal verb). This means the `slot: int` field is REMOVED from
  # `USPMCPushSlotReady` (the slot index is recoverable from the segment's
  # `tail` at the moment of writeItem) and `USPMCPushReady` becomes a plain
  # object so it can carry `pendingItem` (the prior `distinct` shape had no
  # field of its own to extend).
  USPMCPushReady*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    pendingItem*: T

  USPMCPushSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    tail*: int
    pendingItem*: T

  USPMCPushSegmentFull*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    pendingItem*: T

  USPMCPushSlotReady*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    pendingItem*: T

  # New state: the segment we were about to write into got closed (via the
  # LCRQ tri-state cellState protocol or by a peer thread completing the
  # close handshake) between `loadSegment` and the producer's commit. The
  # producer must observe the rotation, retire the closed segment, and
  # try again on the new tail segment. Carries `pendingItem` so the retry
  # loop does not re-evaluate the source expression.
  USPMCPushSegmentClosed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    pendingItem*: T

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
    USPMCPushSegmentClosed[T, S, MT],
    USPMCPushComplete[T, S, MT]
  transitions:
    USPMCPushReady[T, S, MT] -> USPMCPushSegmentLoaded[T, S, MT]
    USPMCPushSegmentLoaded[T, S, MT] ->
      (USPMCPushSlotReady[T, S, MT] | USPMCPushSegmentFull[T, S, MT]) as
      USPMCSegmentCheck[T, S, MT]
    USPMCPushSegmentFull[T, S, MT] -> USPMCPushReady[T, S, MT]
    USPMCPushSegmentClosed[T, S, MT] -> USPMCPushSegmentFull[T, S, MT]
    USPMCPushSlotReady[T, S, MT] ->
      (USPMCPushComplete[T, S, MT] | USPMCPushSegmentLoaded[T, S, MT] |
        USPMCPushSegmentClosed[T, S, MT]) as
      USPMCPushCommitResult[T, S, MT]

# Factory: Create push typestate context from DEBRA's Pinned state.
#
# Task 6 / C-1 fix: `pendingItem: sink T` enters the typestate chain here
# and is threaded through every state until `writeItem` consumes it. This
# keeps the source expression evaluated exactly once (per push) regardless
# of how many SegmentFull / SegmentClosed retry rounds occur.
proc startPush*[T; S, MT: static int](
    pinned: sink Pinned[MT],
    queue: ptr UnboundedSipmucBase[S, T, MT],
    pendingItem: sink T,
): USPMCPushReady[T, S, MT] =
  ## Create push context from DEBRA's Pinned state, carrying the item to
  ## publish into the typestate chain.
  USPMCPushReady[T, S, MT](
    pinnedHandle: pinned.handle,
    pinnedEpoch: pinned.epoch,
    queue: queue,
    pendingItem: pendingItem,
  )

# Extract Pinned state from USPMCPushComplete for unpinning
proc extractPinned*[T; S, MT: static int](
    complete: sink USPMCPushComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

# Extract Pinned state from USPMCPushSegmentClosed for unpinning.
#
# Task 6: SegmentClosed is a non-terminal state in the happy path (the
# producer normally transitions back to Ready and retries). However the
# caller may choose to abandon the push — for example, if the close is
# observed during a shutdown drain — in which case it needs to recover
# the Pinned[MT] handle to call `unpin`. The pendingItem is dropped on
# the floor when this proc consumes the state; that is intentional and
# documented in the facade-level abort path.
proc extractPinned*[T; S, MT: static int](
    closed: sink USPMCPushSegmentClosed[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning from a SegmentClosed
  ## state (caller-initiated abort path). The pendingItem is dropped.
  Pinned[MT](
    EpochGuardContext[MT](handle: closed.pinnedHandle, epoch: closed.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink USPMCPushReady[T, S, MT]
): USPMCPushSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current tail segment and tail position, threading `pendingItem`
  ## forward into SegmentLoaded.
  ## Mirrors production memory ordering: SPMC has a single producer that
  ## owns `tailSegment` (plain ptr), so a relaxed-equivalent direct read
  ## is sufficient. The current segment's `tail` is also producer-only
  ## except for consumer reads that pair with `tail.store(moRelease)`.
  let seg = ready.queue.tailSegment
  let tail = seg.tail.load(moRelaxed)

  USPMCPushSegmentLoaded[T, S, MT](
    pinnedHandle: ready.pinnedHandle,
    pinnedEpoch: ready.pinnedEpoch,
    queue: ready.queue,
    segment: seg,
    tail: tail,
    pendingItem: ready.pendingItem,
  )

# Check full transition
proc checkFull*[T; S, MT: static int](
    loaded: sink USPMCPushSegmentLoaded[T, S, MT]
): USPMCSegmentCheck[T, S, MT] {.transition.} =
  ## Check if segment is full. Returns SlotReady or SegmentFull, threading
  ## `pendingItem` forward into either branch.
  if loaded.tail >= S:
    USPMCSegmentCheck[T, S, MT] ->
      USPMCPushSegmentFull[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        pendingItem: loaded.pendingItem,
      )
  else:
    USPMCSegmentCheck[T, S, MT] ->
      USPMCPushSlotReady[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        pendingItem: loaded.pendingItem,
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
  ## Link new segment and return to Ready state to retry, threading
  ## `pendingItem` forward.
  ## Mirrors production memory ordering: publish the new segment via
  ## `seg.next` (release) so a concurrent consumer that observes the
  ## new next pointer also sees the segment's initialized fields. The
  ## `tailSegment` advance is a plain pointer write — single producer,
  ## no readers other than this producer.
  full.segment.next.store(newSegment, moRelease)
  full.queue.tailSegment = newSegment
  discard full.queue.segments.fetchAdd(1, moRelaxed)

  USPMCPushReady[T, S, MT](
    pinnedHandle: full.pinnedHandle,
    pinnedEpoch: full.pinnedEpoch,
    queue: full.queue,
    pendingItem: full.pendingItem,
  )

# Close-observed transition.
#
# Task 6: New verb (registered in the typestate macro per plan §602 as
# `USPMCPushSegmentClosed -> USPMCPushSegmentFull`). Consumes a
# SegmentClosed surfaced by the facade (Task 7) and yields a SegmentFull
# so the producer's existing SegmentFull -> Ready retry path can rotate
# to a fresh segment via `allocateNewSegment`. The transition does not
# mutate cellState here — that mutation is the responsibility of the
# facade-level close handshake.
proc closeSegmentDone*[T; S, MT: static int](
    closed: sink USPMCPushSegmentClosed[T, S, MT]
): USPMCPushSegmentFull[T, S, MT] {.transition.} =
  ## Bridge SegmentClosed back into the SegmentFull lane so the existing
  ## allocate-and-retry path can rotate to a fresh segment. Threads
  ## `pendingItem` forward to keep the source expression evaluated once.
  USPMCPushSegmentFull[T, S, MT](
    pinnedHandle: closed.pinnedHandle,
    pinnedEpoch: closed.pinnedEpoch,
    queue: closed.queue,
    segment: closed.segment,
    pendingItem: closed.pendingItem,
  )

# Write item transition (Task 11 LCRQ).
#
# Publish-CAS on seg.cellState[myTailSlot]; on CAS-failure (CellClosed),
# Shape A retry: seg.tail.fetchAdd(1, moRelaxed) to obtain a fresh
# myTailSlot, re-attempt publish-CAS. Bounded by StarvingThreshold = S
# per design §3 D5 + §8.
proc writeItem*[T; S, MT: static int](
    slotReady: sink USPMCPushSlotReady[T, S, MT]
): USPMCPushCommitResult[T, S, MT] {.transition.} =
  const StarvingThreshold = S  # I2: per-call const bound to generic S
  let seg = slotReady.segment
  var pending = slotReady.pendingItem  # sink-bound, move-friendly
  # C-1: entry fetchAdd on seg.tail (writeItem is the sole writer; SlotReady
  # carries no slot field). Design §2.3 line 78: "first fetchAdd at writeItem
  # entry (SPMC)". Without this, seg.tail never advances and every push
  # targets slot 0.
  var myTailSlot = seg.tail.fetchAdd(1, moRelaxed)
  if myTailSlot >= S:
    # Segment was already saturated when we arrived; T&S and escalate.
    var expectedClosed: bool = false
    discard seg.closed.compareExchange(
        expectedClosed, true, moAcquireRelease, moAcquire)
    return USPMCPushCommitResult[T, S, MT] ->
      USPMCPushSegmentClosed[T, S, MT](
        pinnedHandle: slotReady.pinnedHandle,
        pinnedEpoch: slotReady.pinnedEpoch,
        queue: slotReady.queue,
        segment: seg,
        pendingItem: move(pending),
      )
  var closureRetryCount = 0
  while true:
    # Publish-CAS attempt.
    # Move-only-T restructure: write the value into the cell with `move`
    # so types lacking copy hooks (e.g. `MoveOnly` in the move-analyzer
    # baseline) compile. The publish-CAS release-fence carries the data
    # write to consumers (design brief §2.4), and the cell value is
    # private to the producer until the CAS wins. On CAS-failure the
    # cell is `CellClosed`; we recover the value back into `pending` via
    # `move(seg.data[myTailSlot])` immediately after the CAS-fail check,
    # leaving the cell in a moved-from state. Soundness today rests on
    # the fact that no consumer writes `CellClosed` (it is set only by
    # this proc's SegmentClosed-escalation T&S CAS on `seg.closed`, which
    # closes the segment, not individual cells). This keeps `pending`
    # valid for both the next loop iteration's data-write and the
    # escalation-branch `pendingItem: move(pending)` transitions.
    seg.data[myTailSlot] = move(pending)
    var expected: uint8 = CellEmpty
    let publishWon = seg.cellState[myTailSlot].compareExchange(
        expected, CellFilled, moAcquireRelease, moAcquire)
    if publishWon:
      # Hook B (Task 7 amendment 2026-05-14): re-anchored from old
      # `tail.store(moRelease)` to new publish-CAS-win site so the
      # awaitingTail-strand stress test still has a deterministic
      # producer-publish gate. See plan §698-784 amended block.
      when defined(awaitingTailTestHook):
        discard producerPublishGoChan.recv()
      discard slotReady.queue.itemCount.fetchAdd(1, moRelaxed)
      return USPMCPushCommitResult[T, S, MT] ->
        USPMCPushComplete[T, S, MT](
          pinnedHandle: slotReady.pinnedHandle,
          pinnedEpoch: slotReady.pinnedEpoch,
          queue: slotReady.queue,
        )
    # CAS failure: cell must be CellClosed. CellFilled is impossible because
    # SPMC has a single producer; the producer's prior writeItem on this slot
    # would have won and exited, never re-entering this slot.
    doAssert expected == CellClosed,
      "SPMC writeItem: cell observed unexpected state on publish-CAS failure"
    # Recover `pending` from the just-failed cell. The cell is `CellClosed`.
    # The CAS-fail recovery path is exercise-dormant in the current code:
    # no consumer writes `CellClosed` today (it is set only by writeItem
    # itself in the SegmentClosed escalation T&S CAS on `seg.closed`,
    # which closes the segment, not individual cells), so the producer is
    # the sole writer to `seg.data[myTailSlot]` and leaving the cell in a
    # moved-from state is sound. Task 9 (per impl plan §904+) introduces
    # consumer-side close-CAS for the awaitingTail-strand bug fix; when
    # that lands, the consumer's `readItem` (currently
    # `unbounded_spmc_pop.nim:251`, tail-bound via `tryClaimSlot`) MUST
    # add a `CellFilled` gate before reading `data[i]`, otherwise this
    # recovery path becomes unsound (a consumer could read a moved-from
    # cell). This pre-condition is a Task 9 design dependency. Recovering
    # here keeps `pending` valid for the next loop iteration's
    # `seg.data[newSlot] = move(pending)` write AND for the
    # escalation-branch transitions below.
    pending = move(seg.data[myTailSlot])
    # I4: assert bound INSIDE increment branch, BEFORE threshold compare.
    closureRetryCount += 1
    doAssert closureRetryCount <= StarvingThreshold,
      "SPMC writeItem: closureRetryCount exceeded StarvingThreshold = S (design §8)"
    let observedTail = seg.tail.load(moRelaxed)
    if closureRetryCount >= StarvingThreshold or observedTail >= S:
      # Starvation: T&S seg.closed and transition to SegmentClosed.
      var expectedClosed: bool = false
      discard seg.closed.compareExchange(
          expectedClosed, true, moAcquireRelease, moAcquire)
      return USPMCPushCommitResult[T, S, MT] ->
        USPMCPushSegmentClosed[T, S, MT](
          pinnedHandle: slotReady.pinnedHandle,
          pinnedEpoch: slotReady.pinnedEpoch,
          queue: slotReady.queue,
          segment: seg,
          pendingItem: move(pending),
        )
    # C5 Shape A retry: fetchAdd seg.tail, adopt new myTailSlot.
    let nextSlot = seg.tail.fetchAdd(1, moRelaxed)
    if nextSlot >= S:
      # Segment saturated mid-retry; T&S and escalate.
      var expectedClosed: bool = false
      discard seg.closed.compareExchange(
          expectedClosed, true, moAcquireRelease, moAcquire)
      return USPMCPushCommitResult[T, S, MT] ->
        USPMCPushSegmentClosed[T, S, MT](
          pinnedHandle: slotReady.pinnedHandle,
          pinnedEpoch: slotReady.pinnedEpoch,
          queue: slotReady.queue,
          segment: seg,
          pendingItem: move(pending),
        )
    myTailSlot = nextSlot
    # Loop to top: publish-CAS at new slot.
