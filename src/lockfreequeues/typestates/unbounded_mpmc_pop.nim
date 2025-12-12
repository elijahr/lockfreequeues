## Typestate for unbounded MPMC pop operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs pop with CAS coordination
## and committed flag check, bridges back. Multiple consumers coordinate via
## CAS on prevConsumerIdx, and must check committed flag before reading.

import atomics
import typestates
import debra

import ./unbounded_mpmc_push  # Reuse MPMCSegment, UnboundedMupmucBase

type
  # Base context
  MPMCPopContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  # States
  MPMCPopReady*[S, MT: static int] = distinct MPMCPopContext[S, MT]

  MPMCPopSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    tail*: int
    prevConsumerIdx*: int

  MPMCPopSlotClaimed*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  MPMCPopSlotUncommitted*[S, MT: static int] = object
    ## Producer claimed slot but hasn't finished writing yet.
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  MPMCPopSegmentExhausted*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  MPMCPopEmpty*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  MPMCPopComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    valuePtr*: pointer
    slot*: int
    isLastSlot*: bool


typestate MPMCPopContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  states MPMCPopReady[S, MT], MPMCPopSegmentLoaded[S, MT],
         MPMCPopSlotClaimed[S, MT], MPMCPopSlotUncommitted[S, MT],
         MPMCPopSegmentExhausted[S, MT], MPMCPopEmpty[S, MT],
         MPMCPopComplete[S, MT]
  transitions:
    MPMCPopReady[S, MT] -> MPMCPopSegmentLoaded[S, MT]
    MPMCPopSegmentLoaded[S, MT] -> (MPMCPopSlotClaimed[S, MT] | MPMCPopSegmentExhausted[S, MT] | MPMCPopSlotUncommitted[S, MT] | MPMCPopReady[S, MT]) as MPMCPopSlotClaimResult[S, MT]
    MPMCPopSlotClaimed[S, MT] -> (MPMCPopComplete[S, MT] | MPMCPopSlotUncommitted[S, MT]) as MPMCPopCommitCheck[S, MT]
    MPMCPopSegmentExhausted[S, MT] -> (MPMCPopReady[S, MT] | MPMCPopEmpty[S, MT]) as MPMCPopAdvanceResult[S, MT]


# Factory
proc startPop*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedMupmucBase[S, T, MT]
): MPMCPopReady[S, MT] =
  MPMCPopReady[S, MT](
    MPMCPopContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


proc extractPinned*[S, MT: static int](
  complete: sink MPMCPopComplete[S, MT]
): Pinned[MT] =
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))

proc extractPinned*[S, MT: static int](
  empty: sink MPMCPopEmpty[S, MT]
): Pinned[MT] =
  Pinned[MT](EpochGuardContext[MT](
    handle: empty.pinnedHandle,
    epoch: empty.pinnedEpoch))

proc extractPinned*[S, MT: static int](
  uncommitted: sink MPMCPopSlotUncommitted[S, MT]
): Pinned[MT] =
  Pinned[MT](EpochGuardContext[MT](
    handle: uncommitted.pinnedHandle,
    epoch: uncommitted.pinnedEpoch))


proc loadSegment*[S, MT: static int](
  ready: sink MPMCPopReady[S, MT]
): MPMCPopSegmentLoaded[S, MT] {.transition.} =
  let ctx = MPMCPopContext[S, MT](ready)
  MPMCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,
    tail: 0,
    prevConsumerIdx: 0)


proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink MPMCPopReady[S, MT]
): MPMCPopSegmentLoaded[S, MT] =
  let ctx = MPMCPopContext[S, MT](ready)
  let queue = cast[ptr UnboundedMupmucBase[S, T, MT]](ctx.queue)
  let seg = queue.headSegment
  let tail = seg.tail.load(moAcquire)
  let prevIdx = seg.prevConsumerIdx.load(moAcquire)

  MPMCPopSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    tail: tail,
    prevConsumerIdx: prevIdx)


# Check committed flag before CAS attempt
proc tryClaimSlot*[S, MT: static int](
  loaded: sink MPMCPopSegmentLoaded[S, MT]
): MPMCPopSlotClaimResult[S, MT] {.transition.} =
  let mySlot = loaded.prevConsumerIdx + 1
  if mySlot >= loaded.tail:
    return MPMCPopSlotClaimResult[S, MT] -> MPMCPopSegmentExhausted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # Default to retry - actual CAS done in typed version
  MPMCPopSlotClaimResult[S, MT] -> MPMCPopReady[S, MT](
    MPMCPopContext[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue))


proc tryClaimSlotTyped*[T; S, MT: static int](
  loaded: sink MPMCPopSegmentLoaded[S, MT]
): MPMCPopSlotClaimResult[S, MT] =
  let seg = cast[ptr MPMCSegment[S, T]](loaded.segment)
  let mySlot = loaded.prevConsumerIdx + 1

  if mySlot >= loaded.tail:
    return MPMCPopSlotClaimResult[S, MT] -> MPMCPopSegmentExhausted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  # Check if slot is committed before trying to claim
  if not seg.committed[mySlot].load(moAcquire):
    return MPMCPopSlotClaimResult[S, MT] -> MPMCPopSlotUncommitted[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue)

  # CAS to claim slot
  var expected = loaded.prevConsumerIdx
  if seg.prevConsumerIdx.compareExchange(expected, mySlot, moAcquire, moRelaxed):
    return MPMCPopSlotClaimResult[S, MT] -> MPMCPopSlotClaimed[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: mySlot)
  else:
    # CAS failed - retry
    return MPMCPopSlotClaimResult[S, MT] -> MPMCPopReady[S, MT](
      MPMCPopContext[S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue))


# Read item from claimed slot
proc readItem*[S, MT: static int](
  claimed: sink MPMCPopSlotClaimed[S, MT]
): MPMCPopCommitCheck[S, MT] {.transition.} =
  # Just check committed - reading done by typed version
  MPMCPopCommitCheck[S, MT] -> MPMCPopSlotUncommitted[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue)


proc readItemTyped*[T; S, MT: static int](
  claimed: sink MPMCPopSlotClaimed[S, MT]
): MPMCPopCommitCheck[S, MT] =
  let queue = cast[ptr UnboundedMupmucBase[S, T, MT]](claimed.queue)
  let seg = cast[ptr MPMCSegment[S, T]](claimed.segment)

  # Double-check committed (should be true if we got here via tryClaimSlotTyped)
  if not seg.committed[claimed.slot].load(moAcquire):
    return MPMCPopCommitCheck[S, MT] -> MPMCPopSlotUncommitted[S, MT](
      pinnedHandle: claimed.pinnedHandle,
      pinnedEpoch: claimed.pinnedEpoch,
      queue: claimed.queue)

  let valuePtr = addr seg.data[claimed.slot]
  discard queue.itemCount.fetchSub(1, moRelaxed)

  MPMCPopCommitCheck[S, MT] -> MPMCPopComplete[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    valuePtr: cast[pointer](valuePtr),
    slot: claimed.slot,
    isLastSlot: claimed.slot == S - 1)


proc advanceSegment*[S, MT: static int](
  exhausted: sink MPMCPopSegmentExhausted[S, MT]
): MPMCPopAdvanceResult[S, MT] {.transition.} =
  MPMCPopAdvanceResult[S, MT] -> MPMCPopEmpty[S, MT](
    pinnedHandle: exhausted.pinnedHandle,
    pinnedEpoch: exhausted.pinnedEpoch,
    queue: exhausted.queue)


proc advanceSegmentTyped*[T; S, MT: static int](
  exhausted: sink MPMCPopSegmentExhausted[S, MT]
): MPMCPopAdvanceResult[S, MT] =
  let seg = cast[ptr MPMCSegment[S, T]](exhausted.segment)
  let nextSeg = seg.next.load(moAcquire)

  if nextSeg == nil:
    return MPMCPopAdvanceResult[S, MT] -> MPMCPopEmpty[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue)

  MPMCPopAdvanceResult[S, MT] -> MPMCPopReady[S, MT](
    MPMCPopContext[S, MT](
      pinnedHandle: exhausted.pinnedHandle,
      pinnedEpoch: exhausted.pinnedEpoch,
      queue: exhausted.queue))


proc getValue*[T; S, MT: static int](
  complete: MPMCPopComplete[S, MT]
): T =
  cast[ptr T](complete.valuePtr)[]
