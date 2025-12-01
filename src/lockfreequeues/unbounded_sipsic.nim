# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Unbounded single-producer, single-consumer queue using linked segments.
##
## Uses epoch-based reclamation for safe memory deallocation.
##
## :param S: Segment size (items per segment). Larger = less allocation,
##           smaller = faster reclamation.
## :param T: Type of data the queue holds.
##
## Both push and pop are wait-free for SPSC.
##
## .. code-block:: nim
##    let manager = newEpochManager()
##    var queue = newUnboundedSipsic[64, int](manager)
##
##    queue.push(42)
##    let item = queue.pop()  # some(42)

import atomics
import options

import ./epoch

# Use C stdlib for thread-safe cross-thread allocation
proc c_calloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}


type
  DeallocationStrategy* = enum
    ## Strategy for segment memory reclamation.
    NeverDeallocate    ## Segments stay allocated forever (highest performance)
    EagerDeallocate    ## Free segments immediately when empty
    Pooled             ## Cache N free segments, free excess (default)

  Segment[S: static int, T] = object
    ## A fixed-size segment in the linked list.
    data: array[S, T]
    next: Atomic[ptr Segment[S, T]]
    head: int  # Consumer read position within segment
    tail: int  # Producer write position within segment

  UnboundedSipsic*[S: static int, T] = object
    ## Unbounded SPSC queue using linked segments.
    ##
    ## :param S: Segment size (compile-time constant).
    ## :param T: Data type.
    manager: EpochManager
    headSegment: ptr Segment[S, T]  # Consumer reads from here
    tailSegment: ptr Segment[S, T]  # Producer writes here
    strategy: DeallocationStrategy
    threadIdx: int  # For epoch pinning
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using C malloc (thread-safe cross-thread).
  result = cast[ptr Segment[S, T]](c_calloc(1, csize_t(sizeof(Segment[S, T]))))
  result.next.store(nil, moRelaxed)
  result.head = 0
  result.tail = 0


proc newUnboundedSipsic*[S: static int, T](
  manager: EpochManager,
  strategy: DeallocationStrategy = Pooled
): UnboundedSipsic[S, T] =
  ## Create a new unbounded SPSC queue.
  ##
  ## :param manager: EpochManager for memory reclamation.
  ## :param strategy: Deallocation strategy (default: Pooled).
  ## :returns: New queue instance.
  result.manager = manager
  result.strategy = strategy
  result.threadIdx = manager.registerThread()

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment = seg
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)


proc segmentCount*[S: static int, T](self: var UnboundedSipsic[S, T]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int, T](self: var UnboundedSipsic[S, T]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc push*[S: static int, T](self: var UnboundedSipsic[S, T], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).
  ##
  ## :param item: Item to push.
  var seg = self.tailSegment

  # Check if current segment is full
  if seg.tail >= S:
    # Allocate new segment
    let newSeg = newSegment[S, T]()
    seg.next.store(newSeg, moRelease)
    self.tailSegment = newSeg
    seg = newSeg
    discard self.segments.fetchAdd(1, moRelaxed)

  # Write item
  seg.data[seg.tail] = item
  inc seg.tail
  discard self.itemCount.fetchAdd(1, moRelaxed)


proc push*[S: static int, T](self: var UnboundedSipsic[S, T], items: openArray[T]) =
  ## Push multiple items.
  ##
  ## :param items: Items to push.
  for item in items:
    self.push(item)


proc pop*[S: static int, T](self: var UnboundedSipsic[S, T]): Option[T] =
  ## Pop a single item.
  ##
  ## :returns: some(T) if available, none(T) if empty.
  let guard {.used.} = self.manager.pin(self.threadIdx)

  var seg = self.headSegment

  # Check if segment is exhausted
  while seg.head >= seg.tail:
    # Try to advance to next segment
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      return none(T)

    # Retire old segment
    if self.strategy != NeverDeallocate:
      self.manager.retire(seg)
      discard self.segments.fetchSub(1, moRelaxed)

    self.headSegment = nextSeg
    seg = nextSeg

  # Read item
  result = some(seg.data[seg.head])
  inc seg.head
  discard self.itemCount.fetchSub(1, moRelaxed)

  # Try to reclaim if eager
  if self.strategy == EagerDeallocate:
    discard self.manager.tryReclaim()


proc pop*[S: static int, T](self: var UnboundedSipsic[S, T], count: int): Option[seq[T]] =
  ## Pop up to count items.
  ##
  ## :param count: Maximum items to pop.
  ## :returns: some(seq[T]) with at least one item, none if empty.
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


proc `=destroy`*[S: static int, T](self: UnboundedSipsic[S, T]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      c_free(seg)
      seg = next
