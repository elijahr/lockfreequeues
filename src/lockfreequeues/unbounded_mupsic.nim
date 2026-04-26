## Unbounded multiple-producer, single-consumer (MPSC) queue using linked segments.
##
## Uses DEBRA+ epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
## - MaxThreads: Maximum number of threads (compile-time constant).
##
## Push is lock-free for multiple producers (CAS coordination).
## Pop is wait-free for the single consumer.
##
## ```nim
## var manager = initDebraManager[4]()
## let consumerHandle = registerThread(manager)
## var queue = newUnboundedMupsic[64, int, 4](addr manager, consumerHandle)
## let producerHandle = registerThread(manager)
## var producer = queue.getProducer(producerHandle)
##
## producer.push(42)
## let item = queue.pop()  # some(42)
## ```

import ./atomic_dsl
import std/options

import debra

type DeallocationStrategy* = enum
  ## Strategy for segment memory reclamation.
  Manual
    ## Retire segments. User calls tryReclaim().
    ## Best for --mm:none (no GC assistance).
  Eager
    ## Retire + immediate tryReclaim() after each segment retirement.
    ## Best for GC environments.

when defined(gcNone):
  const DefaultDeallocationStrategy* = Manual
else:
  const DefaultDeallocationStrategy* = Eager

type
  Segment[S: static int, T] = object ## A fixed-size segment in the linked list.
    data: array[S, T]
    next: Atomic[ptr Segment[S, T]]
    tail: Atomic[int] # CAS coordination for producers
    head: int # Consumer read position within segment (single consumer, no atomic)
    committed: array[S, Atomic[bool]] # Track which slots are ready to read

  UnboundedMupsic*[S: static int, T; MaxThreads: static int] = object
    ## Unbounded MPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment: ptr Segment[S, T] # Consumer reads from here
    tailSegment: Atomic[ptr Segment[S, T]] # Producers write here (atomic for CAS)
    strategy: DeallocationStrategy
    handle: ThreadHandle[MaxThreads] # Consumer's handle (single consumer)
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments
    # Producer tracking
    producerCount: Atomic[int]

  Producer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered producer.
    ##
    ## Producers must call getProducer() before pushing.
    queue: ptr UnboundedMupsic[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads] # Each producer has its own handle

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using Nim's alloc0 (zero-initialized).
  result = cast[ptr Segment[S, T]](alloc0(sizeof(Segment[S, T])))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.head = 0
  for i in 0 ..< S:
    result.committed[i].store(false, moRelaxed)

proc newUnboundedMupsic*[S: static int, T; MaxThreads: static int](
    manager: ptr DebraManager[MaxThreads],
    handle: ThreadHandle[MaxThreads], # Consumer's handle
    strategy: DeallocationStrategy = DefaultDeallocationStrategy,
): UnboundedMupsic[S, T, MaxThreads] =
  ## Create a new unbounded MPSC queue.
  ##
  ## Requires a DebraManager pointer and consumer's ThreadHandle for memory reclamation.
  ## Deallocation strategy defaults based on memory management mode.
  ## Returns a new queue instance.

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "On arc/orc, ref types use spinlock-based atomic operations for reference counting. " &
            "Use a lock-free type (int, pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow spinlock fallback."
        .}

  result.manager = manager
  result.strategy = strategy
  result.handle = handle

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment.store(seg, moRelaxed)
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)

  # Initialize producer tracking
  result.producerCount.store(0, moRelaxed)

proc segmentCount*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads]
): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)

proc len*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads]
): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)

proc getProducer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Register a new producer and get a handle.
  ##
  ## Returns a Producer handle for pushing items.
  let idx = self.producerCount.fetchAdd(1, moAcquire)

  result.queue = addr self
  result.idx = idx
  result.handle = handle

proc push*[S: static int, T; MaxThreads: static int](
    self: var Producer[S, T, MaxThreads], item: T
) =
  ## Push a single item. Never blocks or fails (unbounded).

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  let pinned = unpinned(self.handle).pin()

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
          discard self.queue.tailSegment.compareExchange(
            expectedSeg, newSeg, moRelease, moRelaxed
          )
          discard self.queue.segments.fetchAdd(1, moRelaxed)
          continue
        else:
          # Lost race, free our segment
          dealloc(newSeg)
          continue
      else:
        # Someone else allocated, advance tail segment
        var expectedSeg = seg
        discard self.queue.tailSegment.compareExchange(
          expectedSeg, nextSeg, moRelease, moRelaxed
        )
        continue

    # Try to claim a slot
    var expected = tail
    if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
      # Won the slot
      seg.data[tail] = item
      seg.committed[tail].store(true, moRelease) # Mark as ready to read
      discard self.queue.itemCount.fetchAdd(1, moRelaxed)
      discard pinned.unpin()
      return

    # Lost CAS, retry

proc push*[S: static int, T; MaxThreads: static int](
    self: var Producer[S, T, MaxThreads], items: openArray[T]
) =
  ## Push multiple items.
  for item in items:
    self.push(item)

# Helper to wrap destructor for dealloc
proc segmentDestructor(p: pointer) {.nimcall.} =
  dealloc(p)

proc pop*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads]
): Option[T] =
  ## Pop a single item.
  ##
  ## Returns some(T) if available, none(T) if empty.

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  self.handle.withPin:
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
        # If not committed, producer hasn't finished writing yet; result stays none
        break

      # Segment exhausted, try next
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        break

      # Retire old segment
      if self.strategy != Manual:
        it.retire(cast[pointer](seg), segmentDestructor)
        discard self.segments.fetchSub(1, moRelaxed)

      self.headSegment = nextSeg
      seg = nextSeg

  if self.strategy == Eager:
    self.handle.advanceEvery(64)
    discard reclaimNow(self.handle)

proc pop*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads], count: int
): Option[seq[T]] =
  ## Pop up to count items.
  ##
  ## Returns some(seq[T]) with at least one item, none if empty.
  if count <= 0:
    return none(seq[T])

  var items = newSeq[T]()

  for i in 0 ..< count:
    let item = self.pop()
    if item.isNone:
      break
    items.add(item.get)

  if items.len == 0:
    return none(seq[T])
  return some(items)

proc `=destroy`*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads]
) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      dealloc(seg)
      seg = next
