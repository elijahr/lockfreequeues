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
## # Auto-create: queue owns a private DebraManager, the calling thread
## # is registered as the (single) consumer, and producer threads
## # auto-register on `getProducer()`.
## var queue = newUnboundedMupsic[64, int, 4]()
## var producer = queue.getProducer()
##
## producer.push(42)
## let item = queue.pop()  # some(42), called from the constructing thread.
## ```
##
## For multi-queue setups that share a manager, pass it explicitly:
##
## ```nim
## var manager = initDebraManager[4]()
## let consumerHandle = registerThread(manager)
## var queue = newUnboundedMupsic[64, int, 4](addr manager, consumerHandle)
## let producerHandle = registerThread(manager)
## var producer = queue.getProducer(producerHandle)
## ```
##
## See `unbounded_sipmuc` for documentation of the
## `-d:LockFreeQueuesAdvanceEvery=N` compile-time knob, which also tunes
## this queue's Eager reclamation cadence.

import ./atomic_dsl
import ./backoff
import ./internal/aligned_alloc
import std/options
import std/typetraits
from system/ansi_c import c_free

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
      # CAS coordination for producers
    head: int # Consumer read position within segment (single consumer, no atomic)
    committed {.align: CacheLineBytes.}: array[S, Atomic[bool]]
      # Track which slots are ready to read

  UnboundedMupsic*[S: static int, T; MaxThreads: static int] = object
    ## Unbounded MPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Consumer reads from here
    tailSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Producers write here (atomic for CAS)
    strategy: DeallocationStrategy
    handle: ThreadHandle[MaxThreads] # Consumer's handle (single consumer)
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments
    # Producer tracking
    producerCount: Atomic[int]
    ownsManager: bool
      ## True only when the queue allocated its own private manager via
      ## the no-manager-arg constructor; the manager is destroyed and
      ## freed inside `=destroy` after segment cleanup.

  Producer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered producer.
    ##
    ## Producers must call getProducer() before pushing.
    queue: ptr UnboundedMupsic[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads] # Each producer has its own handle

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## ``{.align.}`` pragmas above land on distinct physical cache lines.
  result = allocAligned[Segment[S, T]]()
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
            "Slots are stored in a shared array; `=copy`/`=sink` hooks mutate the refcount on the same object multiple threads can read or write, which is a race regardless of whether the refcount itself is atomic. " &
            "Use a lock-free type (int, pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  result.manager = manager
  result.strategy = strategy
  result.handle = handle
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

  # Initialize producer tracking
  result.producerCount.store(0, moRelaxed)

proc newUnboundedMupsic*[S: static int, T; MaxThreads: static int](
    strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedMupsic[S, T, MaxThreads] =
  ## Auto-create overload: heap-allocates a private `DebraManager`
  ## owned by this queue, registers the calling thread as the (single)
  ## consumer, and stores its handle. Manager teardown happens inside
  ## this queue's `=destroy` after segment cleanup.
  ##
  ## **Caller must be the consumer thread.** If the queue is constructed
  ## on a different thread than the one that will call `pop`, use the
  ## `(manager, consumerHandle, strategy)` overload with an explicit
  ## handle obtained on the consumer thread.
  ##
  ## For multi-queue setups that share a manager, pass it explicitly.
  let mgr = cast[ptr DebraManager[MaxThreads]](
    c_calloc(1.csize_t, sizeof(DebraManager[MaxThreads]).csize_t)
  )
  if mgr == nil:
    raise newException(
      OutOfMemDefect, "newUnboundedMupsic: c_calloc returned nil"
    )
  try:
    mgr[] = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(mgr[])
    result = newUnboundedMupsic[S, T, MaxThreads](mgr, consumerHandle, strategy)
    result.ownsManager = true
  except:
    # Run the manager's =destroy (drains any limbo bags + asserts the
    # client refcount is zero) before freeing the heap slot. Safe for
    # both partially- and fully-initialized state because c_calloc
    # zeroed it.
    reset(mgr[])
    c_free(mgr)
    raise

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

proc getProducer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Auto-register overload: calls `registerThread(self.manager[])`
  ## internally and returns a Producer. Each call consumes one thread
  ## slot in the manager, and **the slot is not reclaimed when the
  ## Producer is destroyed** — it lives until the manager itself is
  ## destroyed. Calling this in a loop or for short-lived producers
  ## will exhaust `MaxThreads`. Reuse the same Producer per thread,
  ## or use the explicit-handle overload, for long-running managers.
  ## If a thread will use multiple queues sharing a manager, prefer
  ## the explicit-handle overload to avoid burning one slot per queue.
  let handle = registerThread(self.manager[])
  self.getProducer(handle)

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
            # Allocation succeeded; loop to retry slot claim on the new segment.
            # No backoff: this is a success edge, not a CAS-retry failure.
            continue
          else:
            # Lost the segment-alloc race, free our orphan and back off.
            c_free(newSeg)
            backoffOnRetry(spins)
            continue
        else:
          # Someone else allocated; advance tailSegment (best effort) and
          # retry slot claim. No backoff: success edge.
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
        break

      # Lost CAS, retry

proc push*[S: static int, T; MaxThreads: static int](
    self: var Producer[S, T, MaxThreads], items: openArray[T]
) =
  ## Push multiple items.
  for item in items:
    self.push(item)

# Typed destructor for retired segments. Generic over `(S, T)` so we can
# `reset` any managed slots (`string`, `seq`, `ref`, ...) before
# `c_free`'s away the segment block. For POD `T` (`supportsCopyMem`),
# the loop is compile-time-elided.
proc segmentDestructor[S: static int, T](p: pointer) {.nimcall, raises: [].} =
  when not supportsCopyMem(T):
    let seg = cast[ptr Segment[S, T]](p)
    for i in 0 ..< S:
      reset(seg.data[i])
  c_free(p)

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
            "Slots are stored in a shared array; `=copy`/`=sink` hooks mutate the refcount on the same object multiple threads can read or write, which is a race regardless of whether the refcount itself is atomic. " &
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  self.handle.withPin:
    # Re-read headSegment under the pin. Acquire load synchronises with
    # the release store performed when this consumer last advanced the
    # head, ensuring we never observe a freed pointer.
    var seg = self.headSegment.load(moAcquire)

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

      # Single consumer, so no race on headSegment. Advance with release
      # semantics and retire under the active pin so a follow-up reclaim
      # cannot free this segment until every pinned thread observes the
      # advance. Always retire (regardless of strategy) so DEBRA owns the
      # detached segment: Manual mode leaves it in limbo for `tryReclaim`
      # (or `manager.=destroy` at scope exit) to drain; Eager mode reclaims
      # it shortly via the `reclaimNow` call after the pin block. Without
      # retiring, the segment is detached from the head chain but reachable
      # from no root, and leaks at process exit.
      self.headSegment.store(nextSeg, moRelease)
      it.retire(cast[pointer](seg), segmentDestructor[S, T])
      if self.strategy != Manual:
        discard self.segments.fetchSub(1, moRelaxed)
      # With Manual strategy the segment is in limbo (retired but not yet
      # reclaimed); segmentCount keeps reflecting the peak count until the
      # user calls `tryReclaim`.
      seg = nextSeg

  if self.strategy == Eager:
    if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
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

when defined(testing):
  proc headSegmentForTest*[S: static int, T; MaxThreads: static int](
      self: var UnboundedMupsic[S, T, MaxThreads]
  ): pointer =
    ## Test-only accessor: returns the queue's current head segment pointer
    ## so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentHeadOffsetForTest*[S: static int, T; MaxThreads: static int](
      _: typedesc[UnboundedMupsic[S, T, MaxThreads]]
  ): tuple[tail: int, committed: int] =
    ## Test-only accessor: returns offsets of cache-line-padded fields within
    ## the unbounded mupsic Segment for the cache-line padding audit.
    result = (offsetOf(Segment[S, T], tail), offsetOf(Segment[S, T], committed))

proc `=destroy`*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupsic[S, T, MaxThreads]
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
