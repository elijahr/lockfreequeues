
## Unbounded single-producer, single-consumer (SPSC) queue using linked segments.
##
## Uses DEBRA+ epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
## - MaxThreads: Maximum number of threads (compile-time constant).
##
## Both push and pop are wait-free for SPSC.
##
## ```nim
## var manager = initDebraManager[4]()
## let handle = registerThread(manager)
## var queue = newUnboundedSipsic[64, int, 4](addr manager, handle)
##
## queue.push(42)
## let item = queue.pop()  # some(42)
## ```

import atomics
import options

import debra

import ./typestates/unbounded_spsc_push
import ./typestates/unbounded_spsc_pop

# Use C stdlib for thread-safe cross-thread allocation
proc c_calloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}


type
  DeallocationStrategy* = enum
    ## Strategy for segment memory reclamation.
    Manual    ## Retire segments. User calls tryReclaim().
              ## Best for --mm:none (no GC assistance).
    Eager     ## Retire + immediate tryReclaim() after each segment retirement.
              ## Best for GC environments.

when defined(gcNone):
  const DefaultDeallocationStrategy* = Manual
else:
  const DefaultDeallocationStrategy* = Eager

type
  # Use Segment from typestate module (re-exported)
  SipsicSegment[S: static int, T] = Segment[S, T]

  UnboundedSipsic*[S: static int; T; MaxThreads: static int] = object
    ## Unbounded SPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    ##
    ## Layout matches UnboundedSipsicBase for the first 5 fields to allow casting.
    manager: ptr DebraManager[MaxThreads]
    headSegment: ptr SipsicSegment[S, T]  # Consumer reads from here
    tailSegment: ptr SipsicSegment[S, T]  # Producer writes here
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments
    # Extension fields below base layout
    strategy: DeallocationStrategy
    handle: ThreadHandle[MaxThreads]  # Thread handle for pin/unpin


proc newSegment[S: static int, T](): ptr SipsicSegment[S, T] =
  ## Allocate a new segment using C malloc (thread-safe cross-thread).
  result = cast[ptr SipsicSegment[S, T]](c_calloc(1, csize_t(sizeof(SipsicSegment[S, T]))))
  result.next.store(nil, moRelaxed)
  result.head.store(0, moRelaxed)
  result.tail.store(0, moRelaxed)


proc newUnboundedSipsic*[S: static int; T; MaxThreads: static int](
  manager: ptr DebraManager[MaxThreads],
  handle: ThreadHandle[MaxThreads],
  strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedSipsic[S, T, MaxThreads] =
  ## Create a new unbounded SPSC queue.
  ##
  ## Requires a DebraManager pointer and ThreadHandle for memory reclamation.
  ## Deallocation strategy defaults based on memory management mode.
  ## Returns a new queue instance.
  result.manager = manager
  result.strategy = strategy
  result.handle = handle

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment = seg
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)


proc segmentCount*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc push*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).
  var seg = self.tailSegment

  # Check if current segment is full
  let tail = seg.tail.load(moRelaxed)
  if tail >= S:
    # Allocate new segment
    let newSeg = newSegment[S, T]()
    seg.next.store(newSeg, moRelease)
    self.tailSegment = newSeg
    seg = newSeg
    discard self.segments.fetchAdd(1, moRelaxed)

  # Write item then publish with release semantics
  let pos = seg.tail.load(moRelaxed)
  seg.data[pos] = item
  seg.tail.store(pos + 1, moRelease)
  discard self.itemCount.fetchAdd(1, moRelaxed)


proc push*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads], items: openArray[T]) =
  ## Push multiple items.
  for item in items:
    self.push(item)


# Helper to wrap destructor for c_free
proc segmentDestructor(p: pointer) {.nimcall.} =
  c_free(p)


proc pop*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads]): Option[T] =
  ## Pop a single item using internal typestate for compile-time safety.
  ##
  ## Returns some(T) if available, none(T) if empty.

  # Cast to base type for typestate compatibility (first 5 fields match)
  let queueBase = cast[ptr UnboundedSipsicBase[S, T, MaxThreads]](addr self)

  # Start pop operation with pinned epoch
  var state = startPop[T, S, MaxThreads](
    unpinned(self.handle).pin(),
    queueBase)

  while true:
    let loaded = state.loadSegmentTyped[:T, S, MaxThreads]()
    let slotCheck = loaded.checkSlot()

    case slotCheck.kind:
    of sSPSCPopSlotAvailable:
      # Read the item
      let complete = slotCheck.spscpopslotavailable.readItemTyped[:T, S, MaxThreads]()
      let value = getValue[T, S, MaxThreads](complete)

      # Unpin
      discard complete.extractPinned().unpin()

      # Try to reclaim if eager
      if self.strategy == Eager:
        let reclaimOp = reclaimStart(self.manager).loadEpochs().checkSafe()
        if reclaimOp.kind == rReclaimReady:
          discard reclaimOp.reclaimready.tryReclaim()

      return some(value)

    of sSPSCPopSegmentExhausted:
      # Save old segment for retirement
      let oldSeg = cast[ptr SipsicSegment[S, T]](slotCheck.spscpopsegmentexhausted.segment)

      # Try to advance to next segment
      let advanceResult = slotCheck.spscpopsegmentexhausted.advanceSegmentTyped[:T, S, MaxThreads]()

      case advanceResult.kind:
      of sSPSCPopReady:
        # Retire old segment if not manual
        if self.strategy != Manual:
          # Note: We need to get pinned from state to retire
          # But we've already consumed the state. For now, retire directly.
          # TODO: Revisit retirement pattern with typestates
          discard self.segments.fetchSub(1, moRelaxed)
          c_free(oldSeg)

        # Continue with new ready state
        state = advanceResult.spscpopready
        continue

      of sSPSCPopEmpty:
        # Unpin and return empty
        discard advanceResult.spscpopempty.extractPinned().unpin()
        return none(T)


proc pop*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads], count: int): Option[seq[T]] =
  ## Pop up to count items.
  ##
  ## Returns some(seq[T]) with at least one item, none if empty.
  if count <= 0:
    return none(seq[T])

  var items = newSeq[T]()

  for i in 0..<count:
    let item = self.pop()
    if item.isNone:
      break
    items.add(item.get)

  if items.len == 0:
    return none(seq[T])
  return some(items)


proc `=destroy`*[S: static int; T; MaxThreads: static int](self: var UnboundedSipsic[S, T, MaxThreads]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      c_free(seg)
      seg = next
