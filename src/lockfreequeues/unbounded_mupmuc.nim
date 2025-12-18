
## Unbounded multiple-producer, multiple-consumer (MPMC) queue using linked segments.
##
## Uses DEBRA+ epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
## - MaxThreads: Maximum number of threads (compile-time constant).
##
## Both push and pop are lock-free (CAS coordination).
##
## ```nim
## var manager = initDebraManager[4]()
## var queue = newUnboundedMupmuc[64, int, 4](addr manager)
## let producerHandle = registerThread(manager)
## let consumerHandle = registerThread(manager)
## var producer = queue.getProducer(producerHandle)
## var consumer = queue.getConsumer(consumerHandle)
## producer.push(42)
## let item = consumer.pop()  # some(42)
## ```

import atomics
import options

import debra


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
    tail: Atomic[int]  # CAS coordination for producers
    prevConsumerIdx: Atomic[int]  # CAS coordination for consumers
    committed: array[S, Atomic[bool]]  # Track which slots are ready to read

  UnboundedMupmuc*[S: static int; T; MaxThreads: static int] = object
    ## Unbounded MPMC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment: ptr Segment[S, T]  # Consumers read from here
    tailSegment: Atomic[ptr Segment[S, T]]  # Producers write here
    strategy: DeallocationStrategy
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments
    producerCount: Atomic[int]
    consumerCount: Atomic[int]

  Producer*[S: static int; T; MaxThreads: static int] = object
    ## Handle for a registered producer.
    ##
    ## Producers must call getProducer() before pushing.
    queue: ptr UnboundedMupmuc[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads]

  Consumer*[S: static int; T; MaxThreads: static int] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    queue: ptr UnboundedMupmuc[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads]


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using Nim's alloc0 (zero-initialized).
  result = cast[ptr Segment[S, T]](alloc0(sizeof(Segment[S, T])))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  for i in 0..<S:
    result.committed[i].store(false, moRelaxed)


proc newUnboundedMupmuc*[S: static int; T; MaxThreads: static int](
  manager: ptr DebraManager[MaxThreads],
  strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedMupmuc[S, T, MaxThreads] =
  ## Create a new unbounded MPMC queue.
  ##
  ## Requires a DebraManager pointer for memory reclamation.
  ## Deallocation strategy defaults based on memory management mode.
  ## Returns a new queue instance.
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


proc segmentCount*[S: static int; T; MaxThreads: static int](self: var UnboundedMupmuc[S, T, MaxThreads]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int; T; MaxThreads: static int](self: var UnboundedMupmuc[S, T, MaxThreads]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc getProducer*[S: static int; T; MaxThreads: static int](
  self: var UnboundedMupmuc[S, T, MaxThreads],
  handle: ThreadHandle[MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Register a new producer and get a handle.
  ##
  ## Returns a Producer handle for pushing items.
  let idx = self.producerCount.fetchAdd(1, moAcquire)
  result.queue = addr self
  result.idx = idx
  result.handle = handle


proc getConsumer*[S: static int; T; MaxThreads: static int](
  self: var UnboundedMupmuc[S, T, MaxThreads],
  handle: ThreadHandle[MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Register a new consumer and get a handle.
  ##
  ## Returns a Consumer handle for popping items.
  let idx = self.consumerCount.fetchAdd(1, moAcquire)
  result.queue = addr self
  result.idx = idx
  result.handle = handle


proc push*[S: static int; T; MaxThreads: static int](self: var Producer[S, T, MaxThreads], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).
  let pinned = unpinned(self.handle).pin()

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
      discard pinned.unpin()
      return


proc push*[S: static int; T; MaxThreads: static int](self: var Producer[S, T, MaxThreads], items: openArray[T]) =
  ## Push multiple items.
  for item in items:
    self.push(item)


# Helper to wrap destructor for dealloc
proc segmentDestructor(p: pointer) {.nimcall.} =
  dealloc(p)


proc pop*[S: static int; T; MaxThreads: static int](self: var Consumer[S, T, MaxThreads]): Option[T] =
  ## Pop a single item.
  ##
  ## Returns some(T) if available, none(T) if empty.
  let pinned = unpinned(self.handle).pin()

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
          discard pinned.unpin()
          return none(T)
        # Try again
        continue

      # Segment exhausted, try next
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        discard pinned.unpin()
        return none(T)
      seg = nextSeg
      continue

    # Check if this slot is committed
    if not seg.committed[mySlot].load(moAcquire):
      discard pinned.unpin()
      return none(T)  # Producer still writing

    # CAS to claim slot
    if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
      result = some(seg.data[mySlot])
      discard self.queue.itemCount.fetchSub(1, moRelaxed)

      # If we claimed the last slot (S-1), retire segment for reclamation
      if mySlot == S - 1 and self.queue.strategy != Manual:
        let ready = retireReady(pinned)
        discard ready.retire(cast[pointer](seg), segmentDestructor)
        discard self.queue.segments.fetchSub(1, moRelaxed)

      discard pinned.unpin()

      if self.queue.strategy == Eager:
        let reclaimOp = reclaimStart(self.queue.manager).loadEpochs().checkSafe()
        if reclaimOp.kind == rReclaimReady:
          discard reclaimOp.reclaimready.tryReclaim()

      return


proc pop*[S: static int; T; MaxThreads: static int](self: var Consumer[S, T, MaxThreads], count: int): Option[seq[T]] =
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


proc `=destroy`*[S: static int; T; MaxThreads: static int](self: var UnboundedMupmuc[S, T, MaxThreads]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      dealloc(seg)
      seg = next
