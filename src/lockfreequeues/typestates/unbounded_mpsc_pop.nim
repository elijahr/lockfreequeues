## Typestate for unbounded MPSC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with committed flag check,
## bridges back. Single consumer checks committed flag before reading.

import ../atomic_dsl
import typestates
import debra

import ./unbounded_mpsc_push # Reuse UMPSCSegment, UnboundedMupsicBase

type
  # Base context - carries pinned state and queue pointer
  UMPSCPopContext*[T; S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  # States
  UMPSCPopReady*[T; S, MT: static int] = distinct UMPSCPopContext[T, S, MT]

  UMPSCPopSegmentLoaded*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]
    head*: int
    tail*: int

  UMPSCPopSlotAvailable*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]
    slot*: int

  UMPSCPopSlotUncommitted*[T; S, MT: static int] = object
    ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  UMPSCPopSegmentExhausted*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    segment*: ptr UMPSCSegment[S, T]

  UMPSCPopEmpty*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]

  UMPSCPopComplete*[T; S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: ptr UnboundedMupsicBase[S, T, MT]
    value*: T
    slot*: int

typestate UMPSCPopContext[T, S: static int, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = true
  states UMPSCPopReady[T, S, MT],
    UMPSCPopSegmentLoaded[T, S, MT],
    UMPSCPopSlotAvailable[T, S, MT],
    UMPSCPopSlotUncommitted[T, S, MT],
    UMPSCPopSegmentExhausted[T, S, MT],
    UMPSCPopEmpty[T, S, MT],
    UMPSCPopComplete[T, S, MT]
  transitions:
    UMPSCPopReady[T, S, MT] -> UMPSCPopSegmentLoaded[T, S, MT]
    UMPSCPopSegmentLoaded[T, S, MT] ->
      (UMPSCPopSlotAvailable[T, S, MT] | UMPSCPopSegmentExhausted[T, S, MT]) as
      UMPSCSlotCheck[T, S, MT]
    UMPSCPopSlotAvailable[T, S, MT] ->
      (UMPSCPopComplete[T, S, MT] | UMPSCPopSlotUncommitted[T, S, MT]) as
      UMPSCCommitCheck[T, S, MT]
    UMPSCPopSegmentExhausted[T, S, MT] ->
      (UMPSCPopReady[T, S, MT] | UMPSCPopEmpty[T, S, MT]) as UMPSCAdvanceResult[T, S, MT]

# Factory: Create pop typestate context from DEBRA's Pinned state
proc startPop*[T; S, MT: static int](
    pinned: sink Pinned[MT], queue: ptr UnboundedMupsicBase[S, T, MT]
): UMPSCPopReady[T, S, MT] =
  ## Create pop context from DEBRA's Pinned state.
  UMPSCPopReady[T, S, MT](
    UMPSCPopContext[T, S, MT](
      pinnedHandle: pinned.handle, pinnedEpoch: pinned.epoch, queue: queue
    )
  )

# Extract Pinned state from terminal states
proc extractPinned*[T; S, MT: static int](
    complete: sink UMPSCPopComplete[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: complete.pinnedHandle, epoch: complete.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    empty: sink UMPSCPopEmpty[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](handle: empty.pinnedHandle, epoch: empty.pinnedEpoch)
  )

proc extractPinned*[T; S, MT: static int](
    uncommitted: sink UMPSCPopSlotUncommitted[T, S, MT]
): Pinned[MT] =
  ## Extract DEBRA's Pinned state for unpinning.
  Pinned[MT](
    EpochGuardContext[MT](
      handle: uncommitted.pinnedHandle, epoch: uncommitted.pinnedEpoch
    )
  )

# Load segment transition
proc loadSegment*[T; S, MT: static int](
    ready: sink UMPSCPopReady[T, S, MT]
): UMPSCPopSegmentLoaded[T, S, MT] {.transition.} =
  ## Load current head segment and positions.
  ## Mirrors production memory ordering: acquire load on `headSegment`
  ## synchronises with the release store performed by the consumer when it
  ## advanced the head, so we never observe a freed pointer.
  let ctx = UMPSCPopContext[T, S, MT](ready)
  let seg = ctx.queue.headSegment.load(moAcquire)
  let head = seg.head
  let tail = seg.tail.load(moAcquire)

  UMPSCPopSegmentLoaded[T, S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: seg,
    head: head,
    tail: tail,
  )

# Check slot availability transition
proc checkSlot*[T; S, MT: static int](
    loaded: sink UMPSCPopSegmentLoaded[T, S, MT]
): UMPSCSlotCheck[T, S, MT] {.transition.} =
  ## Check if there's data available. Returns SlotAvailable or SegmentExhausted.
  if loaded.head < loaded.tail:
    UMPSCSlotCheck[T, S, MT] ->
      UMPSCPopSlotAvailable[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
        slot: loaded.head,
      )
  else:
    UMPSCSlotCheck[T, S, MT] ->
      UMPSCPopSegmentExhausted[T, S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue,
        segment: loaded.segment,
      )

# Check if slot is committed and read item if ready
proc checkCommitted*[T; S, MT: static int](
    slotAvail: sink UMPSCPopSlotAvailable[T, S, MT]
): UMPSCCommitCheck[T, S, MT] {.transition.} =
  ## Check committed flag and read item if ready.
  if slotAvail.segment.committed[slotAvail.slot].load(moAcquire):
    # Slot is committed, read the item
    let value = slotAvail.segment.data[slotAvail.slot]

    # Advance head (single consumer, no atomic needed)
    slotAvail.segment.head = slotAvail.slot + 1
    discard slotAvail.queue.itemCount.fetchSub(1, moRelaxed)

    return
      UMPSCCommitCheck[T, S, MT] ->
      UMPSCPopComplete[T, S, MT](
        pinnedHandle: slotAvail.pinnedHandle,
        pinnedEpoch: slotAvail.pinnedEpoch,
        queue: slotAvail.queue,
        value: value,
        slot: slotAvail.slot,
      )
  else:
    # Producer hasn't finished writing yet
    return
      UMPSCCommitCheck[T, S, MT] ->
      UMPSCPopSlotUncommitted[T, S, MT](
        pinnedHandle: slotAvail.pinnedHandle,
        pinnedEpoch: slotAvail.pinnedEpoch,
        queue: slotAvail.queue,
      )

# Advance segment transition
proc advanceSegment*[T; S, MT: static int](
    exhausted: sink UMPSCPopSegmentExhausted[T, S, MT]
): UMPSCAdvanceResult[T, S, MT] {.transition.} =
  ## Try to advance to next segment.
  ## Returns Ready if next segment exists, Empty otherwise.
  let nextSeg = exhausted.segment.next.load(moAcquire)

  if nextSeg == nil:
    return
      UMPSCAdvanceResult[T, S, MT] ->
      UMPSCPopEmpty[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )

  # Advance head segment with release semantics so a follow-up reclaim
  # cannot free this segment until pinned threads observe the advance.
  # Mirrors production at `unbounded_mupsic.nim:370`. Segment retirement
  # is the caller's responsibility (the facade owns DEBRA `it.retire`).
  exhausted.queue.headSegment.store(nextSeg, moRelease)

  UMPSCAdvanceResult[T, S, MT] ->
    UMPSCPopReady[T, S, MT](
      UMPSCPopContext[T, S, MT](
        pinnedHandle: exhausted.pinnedHandle,
        pinnedEpoch: exhausted.pinnedEpoch,
        queue: exhausted.queue,
      )
    )

# Note (A3): the popped value lives on `UMPSCPopComplete.value*` (declared
# above as a public field). Callers read `complete.value` directly; no
# `getValue` verb proc is needed. Avoiding the proc shaves one
# generic-instantiation pass per (T, S, MT, mm-mode) tuple from compile time
# and removes a trivial wrapper.
