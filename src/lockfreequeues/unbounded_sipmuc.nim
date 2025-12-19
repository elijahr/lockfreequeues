
## Unbounded single-producer, multiple-consumer (SPMC) queue using linked segments.
##
## Uses DEBRA+ epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
## - MaxThreads: Maximum number of threads (compile-time constant).
##
## Push is wait-free for the single producer.
## Pop is lock-free for multiple consumers (CAS coordination).
##
## ```nim
## var manager = initDebraManager[4]()
## var queue = newUnboundedSipmuc[64, int, 4](addr manager)
## let handle = registerThread(manager)
## var consumer = queue.getConsumer(handle)
##
## queue.push(42)
## let item = consumer.pop()  # some(42)
## ```

import std/atomics
import std/options

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
    tail: Atomic[int]  # Producer write position within segment
    prevConsumerIdx: Atomic[int]  # CAS coordination for consumers

  UnboundedSipmuc*[S: static int; T; MaxThreads: static int] = object
    ## Unbounded SPMC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment: ptr Segment[S, T]  # Consumers read from here
    tailSegment: ptr Segment[S, T]  # Producer writes here
    strategy: DeallocationStrategy
    itemCount: Atomic[int]  # Total items in queue
    segments: Atomic[int]   # Number of segments
    # Consumer tracking
    consumerCount: Atomic[int]
    consumerHeads: array[MaxThreads, Atomic[int]]  # Per-consumer read position

  Consumer*[S: static int; T; MaxThreads: static int] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    ## The consumer is automatically deregistered on destruction.
    queue: ptr UnboundedSipmuc[S, T, MaxThreads]
    idx*: int
    localHead: int  # Local tracking of position
    handle: ThreadHandle[MaxThreads]  # Thread handle for pin/unpin


proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using Nim's alloc0 (zero-initialized).
  result = cast[ptr Segment[S, T]](alloc0(sizeof(Segment[S, T])))
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)  # No consumer yet


proc newUnboundedSipmuc*[S: static int; T; MaxThreads: static int](
  manager: ptr DebraManager[MaxThreads],
  strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedSipmuc[S, T, MaxThreads] =
  ## Create a new unbounded SPMC queue.
  ##
  ## Requires a DebraManager pointer for memory reclamation.
  ## Deallocation strategy defaults based on memory management mode.
  ## Returns a new queue instance.

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item type '" & $T & "' is a ref type. " &
                 "On arc/orc, ref types use spinlock-based atomic operations for reference counting. " &
                 "Use a lock-free type (int, pointer, ptr T, etc.) or compile with " &
                 "-d:allowNonLockFreeQueueItems to explicitly allow spinlock fallback.".}

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
  for i in 0..<MaxThreads:
    result.consumerHeads[i].store(0, moRelaxed)


proc segmentCount*[S: static int; T; MaxThreads: static int](self: var UnboundedSipmuc[S, T, MaxThreads]): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)


proc len*[S: static int; T; MaxThreads: static int](self: var UnboundedSipmuc[S, T, MaxThreads]): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)


proc push*[S: static int; T; MaxThreads: static int](self: var UnboundedSipmuc[S, T, MaxThreads], item: T) =
  ## Push a single item. Never blocks or fails (unbounded).

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item type '" & $T & "' is a ref type. " &
                 "Use -d:allowNonLockFreeQueueItems to allow.".}

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


proc push*[S: static int; T; MaxThreads: static int](self: var UnboundedSipmuc[S, T, MaxThreads], items: openArray[T]) =
  ## Push multiple items.
  for item in items:
    self.push(item)


proc getConsumer*[S: static int; T; MaxThreads: static int](
  self: var UnboundedSipmuc[S, T, MaxThreads],
  handle: ThreadHandle[MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Register a new consumer and get a handle.
  ##
  ## Returns a Consumer handle for popping items.
  ##
  ## Each consumer sees every item exactly once. Items are distributed
  ## among consumers in arrival order (not broadcast).
  let idx = self.consumerCount.fetchAdd(1, moAcquire)
  assert idx < MaxThreads, "Too many consumers (max " & $MaxThreads & ")"

  result.queue = addr self
  result.idx = idx
  result.localHead = 0
  result.handle = handle


# Helper to wrap destructor for dealloc
proc segmentDestructor(p: pointer) {.nimcall.} =
  dealloc(p)


proc pop*[S: static int; T; MaxThreads: static int](self: var Consumer[S, T, MaxThreads]): Option[T] =
  ## Pop a single item.
  ##
  ## Returns some(T) if available, none(T) if empty.

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item type '" & $T & "' is a ref type. " &
                 "Use -d:allowNonLockFreeQueueItems to allow.".}

  let pinned = unpinned(self.handle).pin()

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
        discard pinned.unpin()
        return none(T)
      seg = nextSeg
      continue

    # CAS to claim slot
    if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
      # Won the slot
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

    # Lost CAS, retry


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


proc `=destroy`*[S: static int; T; MaxThreads: static int](self: var UnboundedSipmuc[S, T, MaxThreads]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      dealloc(seg)
      seg = next
