
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
  Segment[S: static int, T] = object
    ## A fixed-size segment in the linked list.
    data: array[S, T]
    next: Atomic[ptr Segment[S, T]]
    head: Atomic[int]  # Consumer read position within segment
    tail: Atomic[int]  # Producer write position within segment

  UnboundedSipsic*[S: static int; T; MaxThreads: static int] = object
    ## Unbounded SPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment: ptr Segment[S, T]  # Consumer reads from here
    tailSegment: ptr Segment[S, T]  # Producer writes here
    strategy: DeallocationStrategy
    handle: ThreadHandle[MaxThreads]  # Thread handle for pin/unpin
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using C malloc (thread-safe cross-thread).
  result = cast[ptr Segment[S, T]](c_calloc(1, csize_t(sizeof(Segment[S, T]))))
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
  ## Pop a single item.
  ##
  ## Returns some(T) if available, none(T) if empty.
  # Pin the thread
  let pinned = unpinned(self.handle).pin()

  var seg = self.headSegment

  # Check if segment is exhausted (acquire tail to sync with producer's release)
  var head = seg.head.load(moRelaxed)
  while head >= seg.tail.load(moAcquire):
    # Try to advance to next segment
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      # Unpin before returning
      discard pinned.unpin()
      return none(T)

    # Retire old segment
    if self.strategy != Manual:
      let ready = retireReady(pinned)
      discard ready.retire(seg, segmentDestructor)
      discard self.segments.fetchSub(1, moRelaxed)

    self.headSegment = nextSeg
    seg = nextSeg
    head = seg.head.load(moRelaxed)

  # Read item then advance head
  result = some(seg.data[head])
  seg.head.store(head + 1, moRelaxed)
  discard self.itemCount.fetchSub(1, moRelaxed)

  # Unpin
  discard pinned.unpin()

  # Try to reclaim if eager
  if self.strategy == Eager:
    let reclaimOp = reclaimStart(self.manager).loadEpochs().checkSafe()
    if reclaimOp.kind == rReclaimReady:
      discard reclaimOp.reclaimready.tryReclaim()


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
