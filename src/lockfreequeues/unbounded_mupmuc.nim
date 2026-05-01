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
## # Auto-create: queue owns a private DebraManager, threads auto-register.
## var queue = newUnboundedMupmuc[64, int, 4]()
## var producer = queue.getProducer()
## var consumer = queue.getConsumer()
## producer.push(42)
## let item = consumer.pop()  # some(42)
## ```
##
## For multi-queue setups that share a manager, pass it explicitly:
##
## ```nim
## var manager = initDebraManager[4]()
## var queue = newUnboundedMupmuc[64, int, 4](addr manager)
## let producerHandle = registerThread(manager)
## let consumerHandle = registerThread(manager)
## var producer = queue.getProducer(producerHandle)
## var consumer = queue.getConsumer(consumerHandle)
## ```
##
## See `unbounded_sipmuc` for documentation of the
## `-d:LockFreeQueuesAdvanceEvery=N` compile-time knob, which also tunes
## this queue's Eager reclamation cadence.

import ./atomic_dsl
import ./backoff
import std/options
import std/typetraits
from system/ansi_c import c_calloc, c_free

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
    next: Atomic[ptr Segment[S, T]]
    tail: Atomic[int] # CAS coordination for producers
    prevConsumerIdx: Atomic[int] # CAS coordination for consumers
    committed: array[S, Atomic[bool]] # Track which slots are ready to read

  UnboundedMupmuc*[S: static int, T; MaxThreads: static int] = object
    ## Unbounded MPMC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment: Atomic[ptr Segment[S, T]] # Consumers read from here
    tailSegment: Atomic[ptr Segment[S, T]] # Producers write here
    strategy: DeallocationStrategy
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments
    producerCount: Atomic[int]
    consumerCount: Atomic[int]
    ownsManager: bool
      ## True only when the queue allocated its own private manager via
      ## the no-manager-arg constructor; the manager is destroyed and
      ## freed inside `=destroy` after segment cleanup.

  Producer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered producer.
    ##
    ## Producers must call getProducer() before pushing.
    queue: ptr UnboundedMupmuc[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads]

  Consumer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    queue: ptr UnboundedMupmuc[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads]

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment via libc calloc (zero-initialized, truly shared).
  result = cast[ptr Segment[S, T]](c_calloc(1.csize_t, sizeof(Segment[S, T]).csize_t))
  if result == nil:
    raise newException(OutOfMemDefect, "newSegment: c_calloc returned nil")
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  for i in 0 ..< S:
    result.committed[i].store(false, moRelaxed)

proc newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](
    manager: ptr DebraManager[MaxThreads],
    strategy: DeallocationStrategy = DefaultDeallocationStrategy,
): UnboundedMupmuc[S, T, MaxThreads] =
  ## Create a new unbounded MPMC queue.
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
  result.tailSegment.store(seg, moRelaxed)
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)
  result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)

proc newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](
    strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedMupmuc[S, T, MaxThreads] =
  ## Auto-create overload: heap-allocates a private `DebraManager`
  ## owned by this queue. Manager teardown happens inside this queue's
  ## `=destroy` after segment cleanup. For multi-queue setups that
  ## share a manager, use the `(manager, strategy)` overload instead.
  let mgr = cast[ptr DebraManager[MaxThreads]](
    c_calloc(1.csize_t, sizeof(DebraManager[MaxThreads]).csize_t)
  )
  if mgr == nil:
    raise newException(
      OutOfMemDefect, "newUnboundedMupmuc: c_calloc returned nil"
    )
  try:
    mgr[] = initDebraManager[MaxThreads]()
    result = newUnboundedMupmuc[S, T, MaxThreads](mgr, strategy)
    result.ownsManager = true
  except:
    c_free(mgr)
    raise

proc segmentCount*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)

proc len*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)

proc getProducer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Register a new producer and get a handle.
  ##
  ## Returns a Producer handle for pushing items.
  let idx = self.producerCount.fetchAdd(1, moAcquire)
  result.queue = addr self
  result.idx = idx
  result.handle = handle

proc getProducer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Auto-register overload: calls `registerThread(self.manager[])`
  ## internally and returns a Producer. Each call consumes one thread
  ## slot in the manager. If a thread will use multiple queues sharing
  ## a manager, prefer the explicit-handle overload to avoid burning
  ## one slot per queue.
  let handle = registerThread(self.manager[])
  self.getProducer(handle)

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Register a new consumer and get a handle.
  ##
  ## Returns a Consumer handle for popping items.
  let idx = self.consumerCount.fetchAdd(1, moAcquire)
  result.queue = addr self
  result.idx = idx
  result.handle = handle

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Auto-register overload: calls `registerThread(self.manager[])`
  ## internally and returns a Consumer. Each call consumes one thread
  ## slot in the manager. If a thread will use multiple queues sharing
  ## a manager, prefer the explicit-handle overload to avoid burning
  ## one slot per queue.
  let handle = registerThread(self.manager[])
  self.getConsumer(handle)

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
            "Slots are stored in a shared array; `=copy`/`=sink` hooks mutate the refcount on the same object multiple threads can read or write, which is a race regardless of whether the refcount itself is atomic. " &
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  self.handle.withPin:
    var spins = InitialSpin
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
            discard self.queue.tailSegment.compareExchange(
              expectedSeg, newSeg, moRelease, moRelaxed
            )
            discard self.queue.segments.fetchAdd(1, moRelaxed)
            # Allocation succeeded; loop to retry slot claim on the new segment.
            # No backoff: this is a success edge, not a CAS-retry failure.
            continue
          else:
            # Lost the segment-alloc race: another producer linked first.
            # Free our orphan segment and back off before retrying.
            c_free(newSeg)
            backoffOnRetry(spins)
            continue
        else:
          # Another producer already linked next; just advance tailSegment
          # (best effort, may CAS-fail because someone else advanced) and
          # retry slot claim on the new segment. No backoff: success edge.
          var expectedSeg = seg
          discard self.queue.tailSegment.compareExchange(
            expectedSeg, nextSeg, moRelease, moRelaxed
          )
          continue

      # Try to claim a slot
      var expected = tail
      if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
        seg.data[tail] = item
        seg.committed[tail].store(true, moRelease)
        discard self.queue.itemCount.fetchAdd(1, moRelaxed)
        break

proc push*[S: static int, T; MaxThreads: static int](
    self: var Producer[S, T, MaxThreads], items: openArray[T]
) =
  ## Push multiple items.
  for item in items:
    self.push(item)

# Typed destructor for retired segments. Must be generic over `(S, T)`
# because the segment's `data: array[S, T]` slots may hold managed types
# (`string`, `seq`, `ref`, ...) whose internal allocations would leak if
# we just `c_free`'d the segment block. For POD `T` (`supportsCopyMem`),
# the `reset` loop is compile-time-elided, so this costs nothing.
proc segmentDestructor[S: static int, T](p: pointer) {.nimcall, raises: [].} =
  when not supportsCopyMem(T):
    let seg = cast[ptr Segment[S, T]](p)
    for i in 0 ..< S:
      reset(seg.data[i])
  c_free(p)

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
    # Re-read headSegment under the pin so a concurrent consumer's
    # retire+advance from a previous pop cannot pull this segment out
    # from under us before we read it.
    var seg = self.queue.headSegment.load(moAcquire)

    var spins = InitialSpin
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
            break
          # Try again
          backoffOnRetry(spins)
          continue

        # Segment exhausted, try to advance to the next one. CAS
        # headSegment from seg to nextSeg; the winner retires.
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break

        var expected = seg
        if self.queue.headSegment.compareExchangeStrong(
          expected, nextSeg, moAcquireRelease, moAcquire
        ):
          # Always retire the detached segment so DEBRA owns it: in Manual
          # mode the user (or `manager.=destroy` at scope exit) drains the
          # limbo bag via `tryReclaim`; in Eager mode the per-pop
          # `reclaimNow` call below does it. Without retiring, the segment
          # is detached from the head chain but reachable from no root, and
          # leaks at process exit. Only the live segmentCount is mode-
          # dependent.
          it.retire(cast[pointer](seg), segmentDestructor[S, T])
          if self.queue.strategy != Manual:
            discard self.queue.segments.fetchSub(1, moRelaxed)
          # With Manual strategy the segment is in limbo (retired but not
          # yet reclaimed); the test contract is that `segmentCount` reports
          # peak until the user calls `tryReclaim`.
          seg = nextSeg
        else:
          # Another consumer already advanced. Pick up its observation.
          seg = expected
        backoffOnRetry(spins)
        continue

      # Check if this slot is committed
      if not seg.committed[mySlot].load(moAcquire):
        break # Producer still writing

      # CAS to claim slot
      if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
        result = some(seg.data[mySlot])
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        break

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

proc `=destroy`*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
) =
  ## Clean up all segments. Releases this queue's client refcount on
  ## the manager; if the queue owns a private manager (auto-create
  ## overload), tears that manager down and frees it.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    let next = seg.next.load(moRelaxed)
    when not supportsCopyMem(T):
      # Run the destructor for any managed slots (string/seq/ref) before
      # `c_free`'s away the segment block — otherwise their internal
      # allocations leak.
      for i in 0 ..< S:
        reset(seg.data[i])
    c_free(seg)
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
      c_free(self.manager)
