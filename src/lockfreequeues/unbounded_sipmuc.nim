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
## # Auto-create: queue owns a private DebraManager, consumers auto-register.
## var queue = newUnboundedSipmuc[64, int, 4]()
## var consumer = queue.getConsumer()
##
## queue.push(42)
## let item = consumer.pop()  # some(42)
## ```
##
## For multi-queue setups that share a manager, pass it explicitly:
##
## ```nim
## var manager = initDebraManager[4]()
## var queue = newUnboundedSipmuc[64, int, 4](addr manager)
## let handle = registerThread(manager)
## var consumer = queue.getConsumer(handle)
## ```
##
## **Compile-time knobs**
##
## - `-d:LockFreeQueuesAdvanceEvery=N` (default 64): cadence at which the
##   unbounded queues' Eager reclamation paths call `advanceEvery` on their
##   DEBRA handle. Lower values advance the global epoch more aggressively
##   (more reclamation work per pop), higher values amortize epoch advancement
##   across more pops at the cost of delaying reclamation. Must be a positive
##   integer.

import ./atomic_dsl
import ./backoff
import ./internal/aligned_alloc
import std/options
import std/typetraits

import debra

const LockFreeQueuesAdvanceEvery {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in this file's Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

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
    next {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
    tail {.align: CacheLineBytes.}: Atomic[int]
      # Producer write position within segment
    prevConsumerIdx {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for consumers

  UnboundedSipmuc*[S: static int, T; MaxThreads: static int] = object
    ## Unbounded SPMC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Consumers read from here
    tailSegment {.align: CacheLineBytes.}: ptr Segment[S, T]
      # Producer writes here (single-producer)
    strategy: DeallocationStrategy
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments
    # Consumer tracking
    consumerCount: Atomic[int]
    consumerHeads: array[MaxThreads, Atomic[int]] # Per-consumer read position
    ownsManager: bool
      ## True only when the queue allocated its own private manager via
      ## the no-manager-arg constructor; the manager is destroyed and
      ## freed inside `=destroy` after segment cleanup.

  Consumer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    ## The consumer is automatically deregistered on destruction.
    queue: ptr UnboundedSipmuc[S, T, MaxThreads]
    idx*: int
    localHead: int # Local tracking of position
    handle: ThreadHandle[MaxThreads] # Thread handle for pin/unpin

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## ``{.align.}`` pragmas above land on distinct physical cache lines.
  result = allocAligned[Segment[S, T]]()
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed) # No consumer yet

proc newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](
    manager: ptr DebraManager[MaxThreads],
    strategy: DeallocationStrategy = DefaultDeallocationStrategy,
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
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks mutate the refcount on the same object multiple threads can read or write, which is a race regardless of whether the refcount itself is atomic. " &
            "Use a lock-free type (int, pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  result.manager = manager
  result.strategy = strategy
  result.ownsManager = false

  # Refcount this queue against the manager so the manager's `=destroy`
  # asserts cleanly if a shared manager is torn down before its queues.
  bindClient(manager[])

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment = seg
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)

  # Initialize consumer tracking
  result.consumerCount.store(0, moRelaxed)
  for i in 0 ..< MaxThreads:
    result.consumerHeads[i].store(0, moRelaxed)

proc newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](
    strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedSipmuc[S, T, MaxThreads] =
  ## Auto-create overload: heap-allocates a private `DebraManager`
  ## owned by this queue. Manager teardown happens inside this queue's
  ## `=destroy` after segment cleanup. For multi-queue setups that
  ## share a manager, use the `(manager, strategy)` overload instead.
  let mgr = allocAligned[DebraManager[MaxThreads]]()
  var ok = false
  try:
    mgr[] = initDebraManager[MaxThreads]()
    result = newUnboundedSipmuc[S, T, MaxThreads](mgr, strategy)
    result.ownsManager = true
    ok = true
  finally:
    # `finally` (not `except:`) so the cleanup also runs on `Defect`-class
    # raises (e.g. `OutOfMemDefect` from inside `initDebraManager`). Under
    # Nim 2.0, bare `except:` matches only `CatchableError`, leaving
    # Defect-shaped failures to leak `mgr`. Run the manager's `=destroy`
    # (drains any limbo bags + asserts the client refcount is zero) before
    # freeing the heap slot. Safe for both partially- and fully-initialized
    # state because `allocAligned` zeroed it.
    if not ok:
      reset(mgr[])
      freeAligned(mgr)

proc segmentCount*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)

proc len*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)

proc push*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads], item: T
) =
  ## Push a single item. Never blocks or fails (unbounded).

  # Compile-time lock-free check
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks mutate the refcount on the same object multiple threads can read or write, which is a race regardless of whether the refcount itself is atomic. " &
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

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

proc push*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads], items: openArray[T]
) =
  ## Push multiple items.
  for item in items:
    self.push(item)

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
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

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Auto-register overload: calls `registerThread(self.manager[])`
  ## internally and returns a Consumer. Each call consumes one thread
  ## slot in the manager, and **the slot is not reclaimed when the
  ## Consumer is destroyed** — it lives until the manager itself is
  ## destroyed. Calling this in a loop or for short-lived consumers
  ## will exhaust `MaxThreads`. Reuse the same Consumer per thread,
  ## or use the explicit-handle overload, for long-running managers.
  ## If a thread will use multiple queues sharing a manager, prefer
  ## the explicit-handle overload to avoid burning one slot per queue.
  let handle = registerThread(self.manager[])
  self.getConsumer(handle)

# Typed destructor for retired segments. Generic over `(S, T)` so we can
# `reset` any managed slots (`string`, `seq`, `ref`, ...) before
# `freeAligned`'s away the segment block. For POD `T` (`supportsCopyMem`),
# the loop is compile-time-elided.
proc segmentDestructor[S: static int, T](p: pointer) {.nimcall, raises: [].} =
  when not supportsCopyMem(T):
    let seg = cast[ptr Segment[S, T]](p)
    for i in 0 ..< S:
      reset(seg.data[i])
  freeAligned(p)

proc pop*[S: static int, T; MaxThreads: static int](
    self: var Consumer[S, T, MaxThreads]
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
            "Slots are stored in a shared array; `=copy`/`=sink` hooks mutate the refcount on the same object multiple threads can read or write, which is a race regardless of whether the refcount itself is atomic. " &
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  self.handle.withPin:
    # Re-read headSegment under the pin so any retire from a prior pop
    # cannot pull the segment out from under us before we read it.
    var seg = self.queue.headSegment.load(moAcquire)

    var spins = InitialSpin
    while true:
      let tail = seg.tail.load(moAcquire)
      var prevIdx = seg.prevConsumerIdx.load(moAcquire)

      # Try to claim the next slot
      let mySlot = prevIdx + 1
      if mySlot >= tail:
        # Segment exhausted, try to advance to the next segment.
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break

        # Try to be the thread that retires this segment by CAS-advancing
        # headSegment from seg to nextSeg. The winner retires; the loser
        # just observes that another thread already advanced and continues.
        var expected = seg
        if self.queue.headSegment.compareExchange(
          expected, nextSeg, moAcquireRelease, moAcquire
        ):
          # Always retire so DEBRA owns the detached segment: Manual mode
          # leaves it in limbo for `tryReclaim` (or `manager.=destroy` at
          # scope exit) to drain; Eager mode reclaims it shortly via the
          # `reclaimNow` call after the pin block. Without retiring, the
          # segment is detached from the head chain but reachable from no
          # root, and leaks at process exit.
          it.retire(cast[pointer](seg), segmentDestructor[S, T])
          if self.queue.strategy != Manual:
            discard self.queue.segments.fetchSub(1, moRelaxed)
          # With Manual strategy the segment is in limbo (retired but not
          # yet reclaimed); segmentCount keeps reflecting the peak count
          # until the user calls `tryReclaim`.
          seg = nextSeg
        else:
          # Another consumer already advanced. expected now points at the
          # current head segment as observed by the CAS failure load.
          seg = expected
        backoffOnRetry(spins)
        continue

      # CAS to claim slot
      if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
        # Won the slot
        result = some(seg.data[mySlot])
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        break

      # Lost CAS, retry

  if self.queue.strategy == Eager:
    if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(self.handle)

proc pop*[S: static int, T; MaxThreads: static int](
    self: var Consumer[S, T, MaxThreads], count: int
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

when defined(testing):
  proc headSegmentForTest*[S: static int, T; MaxThreads: static int](
      self: var UnboundedSipmuc[S, T, MaxThreads]
  ): pointer =
    ## Test-only accessor: returns the queue's current head segment pointer
    ## so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentHeadOffsetForTest*[S: static int, T; MaxThreads: static int](
      _: typedesc[UnboundedSipmuc[S, T, MaxThreads]]
  ): tuple[tail: int, prevConsumerIdx: int] =
    ## Test-only accessor: returns offsets of cache-line-padded fields within
    ## the unbounded sipmuc Segment for the cache-line padding audit.
    result = (offsetOf(Segment[S, T], tail), offsetOf(Segment[S, T], prevConsumerIdx))

proc `=destroy`*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
) =
  ## Clean up all segments. Releases this queue's client refcount on
  ## the manager; if the queue owns a private manager (auto-create
  ## overload), tears that manager down and frees it.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    when not supportsCopyMem(T):
      # Run the destructor for any managed slots (string/seq/ref) before
      # `freeAligned`'s away the segment block — otherwise their internal
      # allocations leak.
      for i in 0 ..< S:
        reset(seg.data[i])
    let next = seg.next.load(moRelaxed)
    freeAligned(seg)
    seg = next

  # Release our refcount on the manager. Conceptually pairs with the
  # `bindClient` call in the constructor. Done after segment cleanup so
  # we are demonstrably finished using the manager before unbinding.
  if self.manager != nil:
    unbindClient(self.manager[])
    if self.ownsManager:
      # Run the manager's destructor (drains limbo bags, asserts
      # clientCount == 0). `reset` invokes the type's `=destroy` hook
      # without the parsing surprise of the backtick form, which trips
      # `expr(nkIdent); unknown node kind` inside a generic destructor.
      reset(self.manager[])
      freeAligned(self.manager)
