## Typestate for unbounded MPMC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with CAS coordination
## and committed flag check, bridges back. Multiple consumers coordinate via
## CAS on prevConsumerIdx, and must check committed flag before reading.

import ../atomic_dsl
import typestates
import debra

import ./unbounded_mpmc_push # Reuse MPMCSegment, UnboundedMupmucBase

type
  # Base context - carries pinned state and queue pointer
  MPMCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  # States
  MPMCPopReady*[T; S, MT: static int] = distinct MPMCPopContext[T, S, MT]

  MPMCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]
    tail*: int
    prevConsumerIdx*: int

  MPMCPopSlotClaimed*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]
    slot*: int

  MPMCPopSlotUncommitted*[T; S, MT: static int] = object
    ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  MPMCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    segment*: ptr MPMCSegment[S, T]

  MPMCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]

  MPMCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupmucBase[S, T, MT]
    value*: T
    slot*: int
    isLastSlot*: bool

typestate MPMCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states MPMCPopReady[T, S, MT],
    MPMCPopSegmentLoaded[T, S, MT],
    MPMCPopSlotClaimed[T, S, MT],
    MPMCPopSlotUncommitted[T, S, MT],
    MPMCPopSegmentExhausted[T, S, MT],
    MPMCPopEmpty[T, S, MT],
    MPMCPopComplete[T, S, MT]
  transitions:
    MPMCPopReady[T, S, MT] -> MPMCPopSegmentLoaded[T, S, MT]
    MPMCPopSegmentLoaded[T, S, MT] ->
      (
        MPMCPopSlotClaimed[T, S, MT] | MPMCPopSegmentExhausted[T, S, MT] |
        MPMCPopSlotUncommitted[T, S, MT] | MPMCPopReady[T, S, MT]
      ) as MPMCPopSlotClaimResult[T, S, MT]
    MPMCPopSlotClaimed[T, S, MT] ->
      (MPMCPopComplete[T, S, MT] | MPMCPopSlotUncommitted[T, S, MT]) as
      MPMCPopCommitCheck[T, S, MT]
    MPMCPopSegmentExhausted[T, S, MT] ->
      (MPMCPopReady[T, S, MT] | MPMCPopEmpty[T, S, MT]) as MPMCPopAdvanceResult[
        T, S, MT
      ]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupmucBase[S, T, MT]
): MPMCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  MPMCPopReady[T, S, MT](
    MPMCPopContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
    complete: sink MPMCPopComplete[T, S, MT]
): Pinned[MT] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    empty: sink MPMCPopEmpty[T, S, MT]
): Pinned[MT] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    uncommitted: sink MPMCPopSlotUncommitted[T, S, MT]
): Pinned[MT] {.notATransition.} =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](
      handle: uncommitted.pinnedHandle, epoch: uncommitted.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink MPMCPopReady[T, S, MT]
): MPMCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  let ctx = MPMCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.prevConsumerIdx.load(moAcquire)

  MPMCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    tail: tail,
    prevConsumerIdx: prevIdx,
  )

# Check committed flag before CAS attempt
proc tryClaimSlot*[T; S, MT: static int](
    loaded: sink MPMCPopSegmentLoaded[T, S, MT]
): MPMCPopSlotClaimResult[T, S, MT] {.transition.} =
  ## Try to claim a slot with CAS coordination.
  ## Returns SlotClaimed, SegmentExhausted, SlotUncommitted, or Ready for retry.
  let seg = loaded.segment
  let mySlot = loaded.prevConsumerIdx + 1

  if mySlot >= loaded.tail:
    return
      MPMCPopSlotClaimResult[T, S, MT] ->
      MPMCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

  # Check if slot is committed before trying to claim
  if not seg.committed[mySlot].load(moAcquire):
    return
      MPMCPopSlotClaimResult[T, S, MT] ->
      MPMCPopSlotUncommitted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
      )

  # CAS to claim slot
  var expected = loaded.prevConsumerIdx
  if seg.prevConsumerIdx.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    return
      MPMCPopSlotClaimResult[T, S, MT] ->
      MPMCPopSlotClaimed[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: mySlot,
      )
  else:
    # CAS failed - retry
    return
      MPMCPopSlotClaimResult[T, S, MT] ->
      MPMCPopReady[T, S, MT](
        MPMCPopContext[T, S, MT](
          pinnedHandle: loaded.pinnedHandle,
          pinnedEpoch: loaded.pinnedEpoch,
          queue: loaded.queue,
        )
      )

# Read item from claimed slot
proc readItem*[T; S, MT: static int](
    claimed: sink MPMCPopSlotClaimed[T, S, MT]
): MPMCPopCommitCheck[T, S, MT] {.transition.} =
  ## Check committed flag and read item if ready.
  let queue = claimed.queue
  let seg = claimed.segment

  # Double-check committed (should be true if we got here via tryClaimSlot)
  if not seg.committed[claimed.slot].load(moAcquire):
    return
      MPMCPopCommitCheck[T, S, MT] ->
      MPMCPopSlotUncommitted[T, S, MT](
        pinnedHandle: claimed.pinnedHandle,
        pinnedEpoch: claimed.pinnedEpoch,
        queue: claimed.queue,
      )

  let value = seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  MPMCPopCommitCheck[T, S, MT] ->
    MPMCPopComplete[T, S, MT](
      pinnedHandle: claimed.pinnedHandle,
      pinnedEpoch: claimed.pinnedEpoch,
      queue: claimed.queue,
      value: value,
      slot: claimed.slot,
      isLastSlot: claimed.slot == S - 1,
    )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
    exhausted: sink MPMCPopSegmentExhausted[T, S, MT]
): MPMCPopAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let seg = exhausted.segment
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return
      MPMCPopAdvanceResult[T, S, MT] ->
      MPMCPopEmpty[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  MPMCPopAdvanceResult[T, S, MT] ->
    MPMCPopReady[T, S, MT](
      MPMCPopContext[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Get value from completed pop
proc getValue*[T; S, MT: static int](
    complete: MPMCPopComplete[T, S, MT]
): T {.notATransition.} =
  ## Extract the popped value.
  complete.value
