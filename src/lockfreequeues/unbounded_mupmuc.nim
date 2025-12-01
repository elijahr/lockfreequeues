# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Unbounded multiple-producer, multiple-consumer queue using linked segments.
##
## Uses epoch-based reclamation for safe memory deallocation.
##
## :param S: Segment size (items per segment). Larger = less allocation,
##           smaller = faster reclamation.
## :param T: Type of data the queue holds.
##
## Both push and pop are lock-free (CAS coordination).
##
## .. code-block:: nim
##    let manager = newEpochManager()
##    var queue = newUnboundedMupmuc[64, int](manager)
##
##    var producer = queue.getProducer()
##    var consumer = queue.getConsumer()
##    producer.push(42)
##    let item = consumer.pop()  # some(42)

import atomics
import options

import ./epoch


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
    prevConsumerIdx: Atomic[int]  # CAS coordination for consumers
    committed: array[S, Atomic[bool]]  # Track which slots are ready to read

  UnboundedMupmuc*[S: static int, T] = object
    ## Unbounded MPMC queue using linked segments.
    ##
    ## :param S: Segment size (compile-time constant).
    ## :param T: Data type.
    manager: EpochManager
    headSegment: ptr Segment[S, T]  # Consumers read from here
    tailSegment: Atomic[ptr Segment[S, T]]  # Producers write here
    strategy: DeallocationStrategy
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments
    producerCount: Atomic[int]
    consumerCount: Atomic[int]

  Producer*[S: static int, T] = object
    ## Handle for a registered producer.
    queue: ptr UnboundedMupmuc[S, T]
    idx*: int
    threadIdx: int

  Consumer*[S: static int, T] = object
    ## Handle for a registered consumer.
    queue: ptr UnboundedMupmuc[S, T]
    idx*: int
    threadIdx: int


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment.
  result = cast[ptr Segment[S, T]](alloc0(sizeof(Segment[S, T])))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  for i in 0..<S:
    result.committed[i].store(false, moRelaxed)


proc newUnboundedMupmuc*[S: static int, T](
  manager: EpochManager,
  strategy: DeallocationStrategy = Pooled
): UnboundedMupmuc[S, T] =
  ## Create a new unbounded MPMC queue.
  ##
  ## :param manager: EpochManager for memory reclamation.
  ## :param strategy: Deallocation strategy (default: Pooled).
  ## :returns: New queue instance.
  result.manager = manager
  result.strategy = strategy

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment.store(seg, moRelaxed)
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)
  result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)


proc segmentCount*[S: static int, T](self: var UnboundedMupmuc[S, T]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int, T](self: var UnboundedMupmuc[S, T]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc getProducer*[S: static int, T](self: var UnboundedMupmuc[S, T]): Producer[S, T] =
  ## Register a new producer and get a handle.
  ##
  ## :returns: A Producer handle for pushing items.
  let idx = self.producerCount.fetchAdd(1, moAcquire)
  let threadIdx = self.manager.registerThread()

  result.queue = addr self
  result.idx = idx
  result.threadIdx = threadIdx


proc getConsumer*[S: static int, T](self: var UnboundedMupmuc[S, T]): Consumer[S, T] =
  ## Register a new consumer and get a handle.
  ##
  ## :returns: A Consumer handle for popping items.
  let idx = self.consumerCount.fetchAdd(1, moAcquire)
  let threadIdx = self.manager.registerThread()

  result.queue = addr self
  result.idx = idx
  result.threadIdx = threadIdx


proc push*[S: static int, T](self: var Producer[S, T], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).
  ##
  ## :param item: Item to push.
  let guard {.used.} = self.queue.manager.pin(self.threadIdx)

  while true:
    var seg = self.queue.tailSegment.load(moAcquire)
    var tail = seg.tail.load(moAcquire)

    # Check if current segment is full
    if tail >= S:
      # Try to allocate new segment
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        let newSeg = newSegment[S, T]()
        var expectedNext: ptr Segment[S, T] = nil
        if seg.next.compareExchange(expectedNext, newSeg, moRelease, moRelaxed):
          var expectedSeg = seg
          discard self.queue.tailSegment.compareExchange(expectedSeg, newSeg, moRelease, moRelaxed)
          discard self.queue.segments.fetchAdd(1, moRelaxed)
          continue
        else:
          dealloc(newSeg)
          continue
      else:
        var expectedSeg = seg
        discard self.queue.tailSegment.compareExchange(expectedSeg, nextSeg, moRelease, moRelaxed)
        continue

    # Try to claim a slot
    var expected = tail
    if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
      seg.data[tail] = item
      seg.committed[tail].store(true, moRelease)
      discard self.queue.itemCount.fetchAdd(1, moRelaxed)
      return


proc push*[S: static int, T](self: var Producer[S, T], items: openArray[T]) =
  ## Push multiple items.
  for item in items:
    self.push(item)


proc pop*[S: static int, T](self: var Consumer[S, T]): Option[T] =
  ## Pop a single item.
  ##
  ## :returns: some(T) if available, none(T) if empty.
  let guard {.used.} = self.queue.manager.pin(self.threadIdx)

  var seg = self.queue.headSegment

  while true:
    let tail = seg.tail.load(moAcquire)
    var prevIdx = seg.prevConsumerIdx.load(moAcquire)

    # Try to claim the next slot
    let mySlot = prevIdx + 1
    if mySlot >= tail:
      # Check if there might be uncommitted items (producer still writing)
      if mySlot < S and seg.tail.load(moAcquire) > mySlot:
        # Slot reserved but maybe not committed yet
        if not seg.committed[mySlot].load(moAcquire):
          return none(T)  # Wait for commit
        # Try again
        continue

      # Segment exhausted, try next
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        return none(T)
      seg = nextSeg
      continue

    # Check if this slot is committed
    if not seg.committed[mySlot].load(moAcquire):
      return none(T)  # Producer still writing

    # CAS to claim slot
    if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
      result = some(seg.data[mySlot])
      discard self.queue.itemCount.fetchSub(1, moRelaxed)
      return


proc pop*[S: static int, T](self: var Consumer[S, T], count: int): Option[seq[T]] =
  ## Pop up to count items.
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


proc `=destroy`*[S: static int, T](self: UnboundedMupmuc[S, T]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      dealloc(seg)
      seg = next
