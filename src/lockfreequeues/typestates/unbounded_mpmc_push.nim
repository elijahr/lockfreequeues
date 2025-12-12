## Typestate for unbounded MPMC push operations.
##
## Bridges from DEBRA's Pinned[MT] state, performs push with CAS coordination
## and committed flags, bridges back. Multiple producers coordinate via CAS on tail.

import atomics
import typestates
import debra

type
  # Segment type for MPMC - has committed flags and prevConsumerIdx
  MPMCSegment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr MPMCSegment[S, T]]
    tail*: Atomic[int]  # CAS coordination for producers
    prevConsumerIdx*: Atomic[int]  # CAS coordination for consumers
    committed*: array[S, Atomic[bool]]  # Track which slots are ready to read

  # Base queue type for MPMC
  UnboundedMupmucBase*[S: static int; T; MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    headSegment*: ptr MPMCSegment[S, T]
    tailSegment*: Atomic[ptr MPMCSegment[S, T]]  # Atomic for CAS
    itemCount*: Atomic[int]
    segments*: Atomic[int]

  # Base context - carries pinned state and queue pointer
  MPMCPushContext*[S, MT: static int] = object of RootObj
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer

  # States
  MPMCPushReady*[S, MT: static int] = distinct MPMCPushContext[S, MT]

  MPMCPushSegmentLoaded*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    tail*: int

  MPMCPushSegmentFull*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer

  MPMCPushSlotClaimed*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  MPMCPushItemWritten*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer
    segment*: pointer
    slot*: int

  MPMCPushComplete*[S, MT: static int] = object
    pinnedHandle*: ThreadHandle[MT]
    pinnedEpoch*: uint64
    queue*: pointer


typestate MPMCPushContext[S, MT: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  states MPMCPushReady[S, MT], MPMCPushSegmentLoaded[S, MT],
         MPMCPushSegmentFull[S, MT], MPMCPushSlotClaimed[S, MT],
         MPMCPushItemWritten[S, MT], MPMCPushComplete[S, MT]
  transitions:
    MPMCPushReady[S, MT] -> MPMCPushSegmentLoaded[S, MT]
    MPMCPushSegmentLoaded[S, MT] -> (MPMCPushSlotClaimed[S, MT] | MPMCPushSegmentFull[S, MT] | MPMCPushReady[S, MT]) as MPMCSlotClaimResult[S, MT]
    MPMCPushSegmentFull[S, MT] -> MPMCPushReady[S, MT]
    MPMCPushSlotClaimed[S, MT] -> MPMCPushItemWritten[S, MT]
    MPMCPushItemWritten[S, MT] -> MPMCPushComplete[S, MT]


# Factory
proc startPush*[T; S, MT: static int](
  pinned: sink Pinned[MT],
  queue: ptr UnboundedMupmucBase[S, T, MT]
): MPMCPushReady[S, MT] =
  MPMCPushReady[S, MT](
    MPMCPushContext[S, MT](
      pinnedHandle: pinned.handle,
      pinnedEpoch: pinned.epoch,
      queue: cast[pointer](queue)))


proc extractPinned*[S, MT: static int](
  complete: sink MPMCPushComplete[S, MT]
): Pinned[MT] =
  Pinned[MT](EpochGuardContext[MT](
    handle: complete.pinnedHandle,
    epoch: complete.pinnedEpoch))


proc loadSegment*[S, MT: static int](
  ready: sink MPMCPushReady[S, MT]
): MPMCPushSegmentLoaded[S, MT] {.transition.} =
  let ctx = MPMCPushContext[S, MT](ready)
  MPMCPushSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: nil,
    tail: 0)


proc loadSegmentTyped*[T; S, MT: static int](
  ready: sink MPMCPushReady[S, MT]
): MPMCPushSegmentLoaded[S, MT] =
  let ctx = MPMCPushContext[S, MT](ready)
  let queue = cast[ptr UnboundedMupmucBase[S, T, MT]](ctx.queue)
  let seg = queue.tailSegment.load(moAcquire)
  let tail = seg.tail.load(moAcquire)

  MPMCPushSegmentLoaded[S, MT](
    pinnedHandle: ctx.pinnedHandle,
    pinnedEpoch: ctx.pinnedEpoch,
    queue: ctx.queue,
    segment: cast[pointer](seg),
    tail: tail)


proc tryClaimSlot*[S, MT: static int](
  loaded: sink MPMCPushSegmentLoaded[S, MT]
): MPMCSlotClaimResult[S, MT] {.transition.} =
  if loaded.tail >= S:
    return MPMCSlotClaimResult[S, MT] -> MPMCPushSegmentFull[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  MPMCSlotClaimResult[S, MT] -> MPMCPushReady[S, MT](
    MPMCPushContext[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue))


proc tryClaimSlotTyped*[T; S, MT: static int](
  loaded: sink MPMCPushSegmentLoaded[S, MT]
): MPMCSlotClaimResult[S, MT] =
  let seg = cast[ptr MPMCSegment[S, T]](loaded.segment)
  let tail = loaded.tail

  if tail >= S:
    return MPMCSlotClaimResult[S, MT] -> MPMCPushSegmentFull[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment)

  var expected = tail
  if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
    return MPMCSlotClaimResult[S, MT] -> MPMCPushSlotClaimed[S, MT](
      pinnedHandle: loaded.pinnedHandle,
      pinnedEpoch: loaded.pinnedEpoch,
      queue: loaded.queue,
      segment: loaded.segment,
      slot: tail)
  else:
    return MPMCSlotClaimResult[S, MT] -> MPMCPushReady[S, MT](
      MPMCPushContext[S, MT](
        pinnedHandle: loaded.pinnedHandle,
        pinnedEpoch: loaded.pinnedEpoch,
        queue: loaded.queue))


proc allocateNewSegment*[S, MT: static int](
  full: sink MPMCPushSegmentFull[S, MT],
  newSegment: pointer
): MPMCPushReady[S, MT] {.transition.} =
  MPMCPushReady[S, MT](
    MPMCPushContext[S, MT](
      pinnedHandle: full.pinnedHandle,
      pinnedEpoch: full.pinnedEpoch,
      queue: full.queue))


proc tryAllocateNewSegmentTyped*[T; S, MT: static int](
  full: sink MPMCPushSegmentFull[S, MT],
  newSegment: ptr MPMCSegment[S, T]
): tuple[ready: MPMCPushReady[S, MT], allocated: bool] =
  let queue = cast[ptr UnboundedMupmucBase[S, T, MT]](full.queue)
  let oldSeg = cast[ptr MPMCSegment[S, T]](full.segment)

  let nextSeg = oldSeg.next.load(moAcquire)
  if nextSeg != nil:
    var expectedSeg = oldSeg
    discard queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
    return (MPMCPushReady[S, MT](
      MPMCPushContext[S, MT](
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue)), false)

  var expectedNext: ptr MPMCSegment[S, T] = nil
  if oldSeg.next.compareExchange(expectedNext, newSegment, moRelease, moRelaxed):
    var expectedSeg = oldSeg
    discard queue.tailSegment.compareExchange(expectedSeg, newSegment, moRelease, moRelaxed)
    discard queue.segments.fetchAdd(1, moRelaxed)
    return (MPMCPushReady[S, MT](
      MPMCPushContext[S, MT](
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue)), true)
  else:
    let winnerSeg = oldSeg.next.load(moAcquire)
    if winnerSeg != nil:
      var expectedSeg = oldSeg
      discard queue.tailSegment.compareExchange(expectedSeg, winnerSeg, moRelease, moRelaxed)
    return (MPMCPushReady[S, MT](
      MPMCPushContext[S, MT](
        pinnedHandle: full.pinnedHandle,
        pinnedEpoch: full.pinnedEpoch,
        queue: full.queue)), false)


proc writeItem*[S, MT: static int](
  claimed: sink MPMCPushSlotClaimed[S, MT]
): MPMCPushItemWritten[S, MT] {.transition.} =
  MPMCPushItemWritten[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot)


proc writeItemTyped*[T; S, MT: static int](
  claimed: sink MPMCPushSlotClaimed[S, MT],
  item: T
): MPMCPushItemWritten[S, MT] =
  let seg = cast[ptr MPMCSegment[S, T]](claimed.segment)
  seg.data[claimed.slot] = item

  MPMCPushItemWritten[S, MT](
    pinnedHandle: claimed.pinnedHandle,
    pinnedEpoch: claimed.pinnedEpoch,
    queue: claimed.queue,
    segment: claimed.segment,
    slot: claimed.slot)


proc markCommitted*[S, MT: static int](
  written: sink MPMCPushItemWritten[S, MT]
): MPMCPushComplete[S, MT] {.transition.} =
  MPMCPushComplete[S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue)


proc markCommittedTyped*[T; S, MT: static int](
  written: sink MPMCPushItemWritten[S, MT]
): MPMCPushComplete[S, MT] =
  let queue = cast[ptr UnboundedMupmucBase[S, T, MT]](written.queue)
  let seg = cast[ptr MPMCSegment[S, T]](written.segment)
  seg.committed[written.slot].store(true, moRelease)
  discard queue.itemCount.fetchAdd(1, moRelaxed)

  MPMCPushComplete[S, MT](
    pinnedHandle: written.pinnedHandle,
    pinnedEpoch: written.pinnedEpoch,
    queue: written.queue)
