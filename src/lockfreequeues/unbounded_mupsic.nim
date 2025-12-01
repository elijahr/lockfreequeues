# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Unbounded multiple-producer, single-consumer (MPSC) queue using linked segments.
##
## Uses epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
##
## Push is lock-free for multiple producers (CAS coordination).
## Pop is wait-free for the single consumer.
##
## ```nim
## let manager = newEpochManager()
## var queue = newUnboundedMupsic[64, int](manager)
##
## var producer = queue.getProducer()
## producer.push(42)
## let item = queue.pop()  # some(42)
## ```

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
    tail: Atomic[int]  # CAS coordination for producers
    head: int  # Consumer read position within segment (single consumer, no atomic)
    committed: array[S, Atomic[bool]]  # Track which slots are ready to read

  UnboundedMupsic*[S: static int, T] = object
    ## Unbounded MPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    manager: EpochManager
    headSegment: ptr Segment[S, T]  # Consumer reads from here
    tailSegment: Atomic[ptr Segment[S, T]]  # Producers write here (atomic for CAS)
    strategy: DeallocationStrategy
    threadIdx: int  # For epoch pinning (consumer)
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments
    # Producer tracking
    producerCount: Atomic[int]

  Producer*[S: static int, T] = object
    ## Handle for a registered producer.
    ##
    ## Producers must call getProducer() before pushing.
    queue: ptr UnboundedMupsic[S, T]
    idx*: int
    threadIdx: int  # Index for epoch manager


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using C malloc (thread-safe cross-thread).
  result = cast[ptr Segment[S, T]](c_calloc(1, csize_t(sizeof(Segment[S, T]))))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.head = 0
  for i in 0..<S:
    result.committed[i].store(false, moRelaxed)


proc newUnboundedMupsic*[S: static int, T](
  manager: EpochManager,
  strategy: DeallocationStrategy = Pooled
): UnboundedMupsic[S, T] =
  ## Create a new unbounded MPSC queue.
  ##
  ## Requires an EpochManager for memory reclamation.
  ## Deallocation strategy defaults to Pooled.
  ## Returns a new queue instance.
  result.manager = manager
  result.strategy = strategy
  result.threadIdx = manager.registerThread()  # For consumer

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment.store(seg, moRelaxed)
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)

  # Initialize producer tracking
  result.producerCount.store(0, moRelaxed)


proc segmentCount*[S: static int, T](self: var UnboundedMupsic[S, T]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int, T](self: var UnboundedMupsic[S, T]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc getProducer*[S: static int, T](self: var UnboundedMupsic[S, T]): Producer[S, T] =
  ## Register a new producer and get a handle.
  ##
  ## Returns a Producer handle for pushing items.
  let idx = self.producerCount.fetchAdd(1, moAcquire)

  # Register with epoch manager for safe memory reclamation
  let threadIdx = self.manager.registerThread()

  result.queue = addr self
  result.idx = idx
  result.threadIdx = threadIdx


proc push*[S: static int, T](self: var Producer[S, T], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).
  let guard {.used.} = self.queue.manager.pin(self.threadIdx)

  while true:
    var seg = self.queue.tailSegment.load(moAcquire)
    var tail = seg.tail.load(moAcquire)

    # Check if current segment is full
    if tail >= S:
      # Try to allocate new segment
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        # No next segment, try to create one
        let newSeg = newSegment[S, T]()
        var expectedNext: ptr Segment[S, T] = nil
        if seg.next.compareExchange(expectedNext, newSeg, moRelease, moRelaxed):
          # Won the allocation race
          var expectedSeg = seg
          discard self.queue.tailSegment.compareExchange(expectedSeg, newSeg, moRelease, moRelaxed)
          discard self.queue.segments.fetchAdd(1, moRelaxed)
          continue
        else:
          # Lost race, free our segment
          c_free(newSeg)
          continue
      else:
        # Someone else allocated, advance tail segment
        var expectedSeg = seg
        discard self.queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
        continue

    # Try to claim a slot
    var expected = tail
    if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
      # Won the slot
      seg.data[tail] = item
      seg.committed[tail].store(true, moRelease)  # Mark as ready to read
      discard self.queue.itemCount.fetchAdd(1, moRelaxed)
      return

    # Lost CAS, retry


proc push*[S: static int, T](self: var Producer[S, T], items: openArray[T]) =
  ## Push multiple items.
  for item in items:
    self.push(item)


proc pop*[S: static int, T](self: var UnboundedMupsic[S, T]): Option[T] =
  ## Pop a single item.
  ##
  ## Returns some(T) if available, none(T) if empty.
  let guard {.used.} = self.manager.pin(self.threadIdx)

  var seg = self.headSegment

  while true:
    let tail = seg.tail.load(moAcquire)

    # Check if there's data to read
    if seg.head < tail:
      # Check if this slot is committed (producer finished writing)
      if seg.committed[seg.head].load(moAcquire):
        result = some(seg.data[seg.head])
        inc seg.head
        discard self.itemCount.fetchSub(1, moRelaxed)
        return
      else:
        # Producer hasn't finished writing yet, spin
        return none(T)

    # Segment exhausted, try next
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      return none(T)

    # Retire old segment
    if self.strategy != NeverDeallocate:
      self.manager.retire(seg)
      discard self.segments.fetchSub(1, moRelaxed)

    self.headSegment = nextSeg
    seg = nextSeg


proc pop*[S: static int, T](self: var UnboundedMupsic[S, T], count: int): Option[seq[T]] =
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


proc `=destroy`*[S: static int, T](self: UnboundedMupsic[S, T]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      c_free(seg)
      seg = next
