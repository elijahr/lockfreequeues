## Typestate for unbounded SPMC pop operations.
##
## Multiple consumers coordinate via CAS on `consumerHead`. SPMC has
## NO `committed` array — the producer's release store on `tail` is the
## publication signal that consumers acquire-load before reading.
##
## State names are U-prefixed (Unbounded) to avoid registry collision with
## the bounded SPMC* graph (typestates 0.8.0 keys by base state name).

import ../atomic_dsl
import typestates
import debra

import ./unbounded_spmc_push # Reuse Segment, UnboundedSipmucBase

type
  # Base context - carries pinned state and queue pointer
  USPMCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  # States (U-prefix per overlay #5)
  USPMCPopReady*[T; S, MT: static int] = distinct USPMCPopContext[T, S, MT]

  USPMCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    tail*: int
    consumerHead*: int

  USPMCPopSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]
    slot*: int

  USPMCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    segment*: ptr Segment[S, T]

  USPMCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]

  USPMCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedSipmucBase[S, T, MT]
    value*: T
    slot*: int
    isLastSlot*: bool

typestate USPMCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states USPMCPopReady[T, S, MT],
    USPMCPopSegmentLoaded[T, S, MT],
    USPMCPopSlotClaimed[T, S, MT],
    USPMCPopSegmentExhausted[T, S, MT],
    USPMCPopEmpty[T, S, MT],
    USPMCPopComplete[T, S, MT]
  transitions:
    USPMCPopReady[T, S, MT] -> USPMCPopSegmentLoaded[T, S, MT]
    USPMCPopSegmentLoaded[T, S, MT] ->
      (
        USPMCPopSlotClaimed[T, S, MT] | USPMCPopSegmentExhausted[T, S, MT] |
        USPMCPopReady[T, S, MT]
      ) as USPMCSlotClaimResult[T, S, MT]
    USPMCPopSlotClaimed[T, S, MT] -> USPMCPopComplete[T, S, MT]
    USPMCPopSegmentExhausted[T, S, MT] ->
      (USPMCPopReady[T, S, MT] | USPMCPopEmpty[T, S, MT]) as
      USPMCAdvanceResult[T, S, MT]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedSipmucBase[S, T, MT]
): USPMCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  USPMCPopReady[T, S, MT](
    USPMCPopContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
    complete: sink USPMCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    empty: sink USPMCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink USPMCPopReady[T, S, MT]
): USPMCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  ## Mirrors production memory ordering: acquire load on `headSegment`
  ## synchronises with the consumer-side release store performed when a
  ## prior consumer advanced the head, so we never observe a freed
  ## pointer. `tail` and `consumerHead` are acquire-loaded so the
  ## producer's `tail.store(moRelease)` and other consumers' CAS
  ## successes happen-before this load.
  let ctx = USPMCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.consumerHead.load(moAcquire)

  USPMCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    consumerHead: prevIdx,
  )

# Try to claim slot with CAS
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink USPMCPopSegmentLoaded[T, S, MT]
): USPMCSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot using CAS on `consumerHead`. Returns:
  ## - SlotClaimed: CAS succeeded, slot is ours
  ## - SegmentExhausted: no more slots in segment
  ## - Ready: CAS failed, retry from beginning
  ##
  ## Item-loss livelock fix: when the snapshotted `loaded.tail` says we are
  ## exhausted, we MUST re-read `seg.tail` with acquire ordering before
  ## committing to that conclusion. The single producer's `tail.store(...,
  ## moRelease)` after each `data[slot] = item` write may have advanced
  ## past the snapshot taken in `loadSegment`. If we trust the stale
  ## snapshot and propagate to `advanceSegment`, the facade will CAS-
  ## advance `headSegment` past a segment that still has unclaimed items —
  ## those items become unreachable when the segment is retired, and
  ## `pop` returns `none` indefinitely while the test loop spins. The
  ## fresh acquire-load synchronises with the producer's release-store,
  ## so any newly published slot in this segment is observed before we
  ## decide to advance.
  let seg = loaded.segment
  # Note: loaded.consumerHead is a snapshot. A consumer that
  # races with another consumer's CAS will see a stale value here,
  # but the resulting CAS attempt will simply fail (expected != actual)
  # and the loop re-iterates via the Ready arm. Benign; not a livelock.
  let mySlot = loaded.consumerHead + 1

  if mySlot >= loaded.tail:
    # Re-load tail with acquire to pair with the producer's release-store.
    # If the producer published more slots since `loadSegment`, fall
    # through to the CAS path. If the segment really is exhausted, the
    # fresh load returns the same value and we transition to Exhausted
    # as before.
    let freshTail = seg.tail.load(moAcquire)
    if mySlot >= freshTail:
      return
        USPMCSlotClaimResult[T, S, MT] ->
        USPMCPopSegmentExhausted[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
          segment: loaded.segment,
        )

  # Try CAS
  var expected = loaded.consumerHead
  if seg.consumerHead.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    # Won the slot
    return
      USPMCSlotClaimResult[T, S, MT] ->
      USPMCPopSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: mySlot,
      )
  else:
    # CAS failed - retry from beginning
    return
      USPMCSlotClaimResult[T, S, MT] ->
      USPMCPopReady[T, S, MT](
        USPMCPopContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Read item from claimed slot
proc readItem*[T; S, MT: static int](
    claimed: sink USPMCPopSlotClaimed[T, S, MT]
): USPMCPopComplete[T, S, MT] {.transition.} =
  ## Read item from claimed slot.
  let queue = claimed.queue
  let seg = claimed.segment
  let value = seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  USPMCPopComplete[T, S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    value: value,
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1,
  )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
    exhausted: sink USPMCPopSegmentExhausted[T, S, MT]
): USPMCAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  ## Note: SPMC's headSegment advance is the facade's responsibility
  ## (consumer-vs-consumer CAS coordination on `headSegment.compareExchange`
  ## happens at the call site, not here, so the typestate stays single-CAS-
  ## free for the verb pipeline). The facade also retires the old segment
  ## via DEBRA when it wins the headSegment CAS.
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return
      USPMCAdvanceResult[T, S, MT] ->
      USPMCPopEmpty[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  USPMCAdvanceResult[T, S, MT] ->
    USPMCPopReady[T, S, MT](
      USPMCPopContext[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Note (A3): the popped value lives on `USPMCPopComplete.value*` (declared
# above as a public field). Callers read `complete.value` directly; no
# `getValue` verb proc is needed. Avoiding the proc shaves one
# generic-instantiation pass per (T, S, MT, mm-mode) tuple from compile time
# and removes a trivial wrapper.
