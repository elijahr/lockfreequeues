## Unbounded single-producer, single-consumer (SPSC) queue using linked segments.
##
## Uses libc malloc/free for segment storage (truly process-shared, no
## per-thread heap routing). No DEBRA needed for SPSC.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
##
## Both push and pop are wait-free for SPSC.
##
## ```nim
## var queue = newUnboundedSipsic[64, int]()
##
## queue.push(42)
## let item = queue.pop()  # some(42)
## ```
##
## v4.3 facade migration: this module is a thin facade over the typestate
## verbs in ``typestates/unbounded_spsc_push`` and
## ``typestates/unbounded_spsc_pop``. Production owns the canonical memory
## layout (Queue and Segment); the typestate Base type's layout equivalence
## is gated by per-field offsetOf / sizeof static-asserts below.

import ./atomic_dsl
import ./internal/aligned_alloc
import std/options
import std/typetraits

import typestates
import ./typestates/unbounded_spsc_push as ts_spsc_push
import ./typestates/unbounded_spsc_pop as ts_spsc_pop

type
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]

  UnboundedSipsic*[S: static int, T] = object
    ## Unbounded SPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Consumer reads from here
    tailSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Producer writes here
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments

# Layout-equivalence gates: production Queue and Segment must have identical
# field offsets (and sizeof) to the typestate Base type/Segment so that the
# `cast[ptr UnboundedSipsicBase[S, T]](addr self)` in push/pop and the
# typestate's per-Segment-field accesses are sound. See design §2.2 / §3
# Item 2 (SPSC row: 4 fields, both head/tail Segment as Atomic[ptr]).
static:
  # Queue-type equivalence (4 fields + sizeof).
  doAssert offsetOf(UnboundedSipsic[64, int], headSegment) ==
    offsetOf(ts_spsc_push.UnboundedSipsicBase[64, int], headSegment)
  doAssert offsetOf(UnboundedSipsic[64, int], tailSegment) ==
    offsetOf(ts_spsc_push.UnboundedSipsicBase[64, int], tailSegment)
  doAssert offsetOf(UnboundedSipsic[64, int], itemCount) ==
    offsetOf(ts_spsc_push.UnboundedSipsicBase[64, int], itemCount)
  doAssert offsetOf(UnboundedSipsic[64, int], segments) ==
    offsetOf(ts_spsc_push.UnboundedSipsicBase[64, int], segments)
  doAssert sizeof(UnboundedSipsic[64, int]) ==
    sizeof(ts_spsc_push.UnboundedSipsicBase[64, int])
  # Per-Segment-field equivalence (SPSC Segment fields: data, next, head, tail).
  doAssert sizeof(Segment[64, int]) == sizeof(ts_spsc_push.Segment[64, int])
  doAssert offsetOf(Segment[64, int], data) ==
    offsetOf(ts_spsc_push.Segment[64, int], data)
  doAssert offsetOf(Segment[64, int], next) ==
    offsetOf(ts_spsc_push.Segment[64, int], next)
  doAssert offsetOf(Segment[64, int], head) ==
    offsetOf(ts_spsc_push.Segment[64, int], head)
  doAssert offsetOf(Segment[64, int], tail) ==
    offsetOf(ts_spsc_push.Segment[64, int], tail)

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## ``{.align.}`` pragmas above land on distinct physical cache lines
  ## rather than sharing the 16-byte-aligned base that ``c_calloc`` returns.
  result = allocAligned[Segment[S, T]]()
  result.next.store(nil, moRelaxed)
  result.head.store(0, moRelaxed)
  result.tail.store(0, moRelaxed)

proc newUnboundedSipsic*[S: static int, T](): UnboundedSipsic[S, T] =
  ## Create a new unbounded SPSC queue.
  ##
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

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
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

  # Cast queue to UnboundedSipsicBase for typestate compatibility (sound per
  # the static offsetof asserts at the top of this module). Production
  # Segment and the typestate-local ts_spsc_push.Segment also have identical
  # layouts, so pointer equality and field offsets are interchangeable.
  let queueBase = cast[ptr ts_spsc_push.UnboundedSipsicBase[S, T]](addr self)

  # Granular pipeline: startPush -> loadSegment -> checkFull
  #   -> { writeItem (publish via tail.store(moRelease))
  #      | allocateNewSegment then retry }
  while true:
    var loaded = ts_spsc_push.startPush[T, S](queueBase).loadSegment()
    var check = loaded.checkFull()
    match check:
      SPSCPushSlotReady(slotReady):
        discard slotReady.writeItem(item)
        return
      SPSCPushSegmentFull(full):
        let newSeg = cast[ptr ts_spsc_push.Segment[S, T]](newSegment[S, T]())
        discard full.allocateNewSegment(newSeg)
        # Loop back to retry: loadSegment will pick up the freshly published
        # tailSegment via the next-iteration relaxed load.
        continue

proc push*[S: static int, T](self: var UnboundedSipsic[S, T], items: openArray[T]) =
  ## Push multiple items.
  # Bulk variant: per-iteration single-item call has its own (no-op) pin scope.
  for item in items:
    self.push(item)

proc pop*[S: static int, T](self: var UnboundedSipsic[S, T]): Option[T] =
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

  # Cast queue to UnboundedSipsicBase for typestate compatibility (sound per
  # the static offsetof asserts at the top of this module).
  let queueBase = cast[ptr ts_spsc_push.UnboundedSipsicBase[S, T]](addr self)

  # Granular pipeline: startPop -> loadSegment -> checkSlot
  #   -> { readItem -> some(value)
  #      | advanceSegment -> { Empty -> none ; Ready -> free old, retry } }
  while true:
    var loaded = ts_spsc_pop.startPop[T, S](queueBase).loadSegment()
    var check = loaded.checkSlot()
    match check:
      USPSCPopSlotAvailable(slotAvail):
        let complete = slotAvail.readItem()
        return some(ts_spsc_pop.getValue(complete))
      USPSCPopSegmentExhausted(exhausted):
        # Capture the old segment pointer BEFORE the typestate consumes the
        # state — the facade owns segment lifetime since the typestate has
        # no DEBRA dependency.
        let oldSeg = cast[ptr Segment[S, T]](exhausted.segment)
        var advance = exhausted.advanceSegment()
        match advance:
          USPSCPopEmpty(_):
            return none(T)
          USPSCPopReady(_):
            # F1' may return Ready WITHOUT advancing headSegment (abort-and-
            # retry path: producer published more between checkSlot and the
            # commit point). Single-consumer SPSC means only this thread
            # frees, so re-loading headSegment is race-free wrt freeing.
            let curHead = queueBase.headSegment.load(moAcquire)
            if curHead != oldSeg:
              freeAligned(oldSeg)
            continue

proc pop*[S: static int, T](
    self: var UnboundedSipsic[S, T], count: int
): Option[seq[T]] =
  ## Pop up to count items.
  ##
  ## Returns some(seq[T]) with at least one item, none if empty.
  if count <= 0:
    return none(seq[T])

  var items = newSeq[T]()

  # Bulk variant: per-iteration single-item call has its own (no-op) pin scope.
  for i in 0 ..< count:
    let item = self.pop()
    if item.isNone:
      break
    items.add(item.get)

  if items.len == 0:
    return none(seq[T])
  return some(items)

when defined(testing):
  proc headSegmentForTest*[S: static int, T](
      self: var UnboundedSipsic[S, T]
  ): pointer =
    ## Test-only accessor: returns the queue's current head segment pointer
    ## so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentHeadOffsetForTest*[S: static int, T](
      _: typedesc[UnboundedSipsic[S, T]]
  ): tuple[head: int, tail: int] =
    ## Test-only accessor: returns offsets of cache-line-padded fields within
    ## the unbounded sipsic Segment for the cache-line padding audit.
    result = (offsetOf(Segment[S, T], head), offsetOf(Segment[S, T], tail))

proc `=destroy`*[S: static int, T](self: var UnboundedSipsic[S, T]) =
  ## Clean up all segments.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    let next = seg.next.load(moRelaxed)
    when not supportsCopyMem(T):
      # Run the destructor for any managed slots (string/seq/ref) before
      # `freeAligned`'s away the segment block — otherwise their internal
      # allocations leak.
      for i in 0 ..< S:
        reset(seg.data[i])
    freeAligned(seg)
    seg = next
