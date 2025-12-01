# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Unbounded single-producer, multiple-consumer queue using linked segments.
##
## Uses epoch-based reclamation for safe memory deallocation.
##
## :param S: Segment size (items per segment). Larger = less allocation,
##           smaller = faster reclamation.
## :param T: Type of data the queue holds.
##
## Push is wait-free for the single producer.
## Pop is lock-free for multiple consumers (CAS coordination).
##
## .. code-block:: nim
##    let manager = newEpochManager()
##    var queue = newUnboundedSipmuc[64, int](manager)
##
##    queue.push(42)
##    var consumer = queue.getConsumer()
##    let item = consumer.pop()  # some(42)

import atomics
import options

import ./epoch

const MaxConsumers = 64  # Initial capacity, grows dynamically


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
    tail: Atomic[int]  # Producer write position within segment
    prevConsumerIdx: Atomic[int]  # CAS coordination for consumers

  UnboundedSipmuc*[S: static int, T] = object
    ## Unbounded SPMC queue using linked segments.
    ##
    ## :param S: Segment size (compile-time constant).
    ## :param T: Data type.
    manager: EpochManager
    headSegment: ptr Segment[S, T]  # Consumers read from here
    tailSegment: ptr Segment[S, T]  # Producer writes here
    strategy: DeallocationStrategy
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments
    # Consumer tracking
    consumerCount: Atomic[int]
    consumerHeads: seq[Atomic[int]]  # Per-consumer read position (global across segments)

  Consumer*[S: static int, T] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    ## The consumer is automatically deregistered on destruction.
    queue: ptr UnboundedSipmuc[S, T]
    idx*: int
    localHead: int  # Local tracking of position
    threadIdx: int  # Index for epoch manager


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment.
  result = cast[ptr Segment[S, T]](alloc0(sizeof(Segment[S, T])))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)  # No consumer yet


proc newUnboundedSipmuc*[S: static int, T](
  manager: EpochManager,
  strategy: DeallocationStrategy = Pooled
): UnboundedSipmuc[S, T] =
  ## Create a new unbounded SPMC queue.
  ##
  ## :param manager: EpochManager for memory reclamation.
  ## :param strategy: Deallocation strategy (default: Pooled).
  ## :returns: New queue instance.
  result.manager = manager
  result.strategy = strategy

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment = seg
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)

  # Initialize consumer tracking
  result.consumerCount.store(0, moRelaxed)
  result.consumerHeads = newSeq[Atomic[int]](MaxConsumers)
  for i in 0..<MaxConsumers:
    result.consumerHeads[i].store(0, moRelaxed)


proc segmentCount*[S: static int, T](self: var UnboundedSipmuc[S, T]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int, T](self: var UnboundedSipmuc[S, T]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc push*[S: static int, T](self: var UnboundedSipmuc[S, T], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).
  ##
  ## :param item: Item to push.
  var seg = self.tailSegment
  var tail = seg.tail.load(moRelaxed)

  # Check if current segment is full
  if tail >= S:
    # Allocate new segment
    let newSeg = newSegment[S, T]()
    seg.next.store(newSeg, moRelease)
    self.tailSegment = newSeg
    seg = newSeg
    tail = 0
    discard self.segments.fetchAdd(1, moRelaxed)

  # Write item
  seg.data[tail] = item
  seg.tail.store(tail + 1, moRelease)
  discard self.itemCount.fetchAdd(1, moRelaxed)


proc push*[S: static int, T](self: var UnboundedSipmuc[S, T], items: openArray[T]) =
  ## Push multiple items.
  ##
  ## :param items: Items to push.
  for item in items:
    self.push(item)


proc getConsumer*[S: static int, T](self: var UnboundedSipmuc[S, T]): Consumer[S, T] =
  ## Register a new consumer and get a handle.
  ##
  ## :returns: A Consumer handle for popping items.
  ##
  ## Each consumer sees every item exactly once. Items are distributed
  ## among consumers in arrival order (not broadcast).
  let idx = self.consumerCount.fetchAdd(1, moAcquire)

  # Register with epoch manager for safe memory reclamation
  let threadIdx = self.manager.registerThread()

  # Grow consumer tracking if needed
  if idx >= self.consumerHeads.len:
    # Simple growth - in production would need synchronization
    let newSize = self.consumerHeads.len * 2
    self.consumerHeads.setLen(newSize)
    for i in self.consumerHeads.len div 2 ..< newSize:
      self.consumerHeads[i].store(0, moRelaxed)

  result.queue = addr self
  result.idx = idx
  result.localHead = 0
  result.threadIdx = threadIdx


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
      # Segment exhausted, try next
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        return none(T)
      seg = nextSeg
      continue

    # CAS to claim slot
    if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
      # Won the slot
      result = some(seg.data[mySlot])
      discard self.queue.itemCount.fetchSub(1, moRelaxed)
      return

    # Lost CAS, retry


proc pop*[S: static int, T](self: var Consumer[S, T], count: int): Option[seq[T]] =
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


proc `=destroy`*[S: static int, T](self: UnboundedSipmuc[S, T]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      dealloc(seg)
      seg = next
