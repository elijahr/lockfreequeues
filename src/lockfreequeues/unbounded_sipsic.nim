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

import ./atomic_dsl
import ./internal/aligned_alloc
import std/options
import std/typetraits
from system/ansi_c import c_free

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

  var seg = self.tailSegment.load(moRelaxed)

  # Check if current segment is full
  let tail = seg.tail.load(moRelaxed)
  if tail >= S:
    # Allocate new segment. Publish via seg.next first (release) so a
    # concurrent consumer that observes the new next pointer also sees
    # the segment's initialized fields. Then publish via tailSegment.
    let newSeg = newSegment[S, T]()
    seg.next.store(newSeg, moRelease)
    self.tailSegment.store(newSeg, moRelease)
    seg = newSeg
    discard self.segments.fetchAdd(1, moRelaxed)

  # Write item then publish with release semantics
  let pos = seg.tail.load(moRelaxed)
  seg.data[pos] = item
  seg.tail.store(pos + 1, moRelease)
  discard self.itemCount.fetchAdd(1, moRelaxed)

proc push*[S: static int, T](self: var UnboundedSipsic[S, T], items: openArray[T]) =
  ## Push multiple items.
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

  # SPSC: only the consumer reads/writes headSegment. Acquire load picks up
  # the producer's release stores to seg.next when we cross segments.
  var seg = self.headSegment.load(moAcquire)

  while true:
    let head = seg.head.load(moRelaxed)
    let tail = seg.tail.load(moAcquire)

    # Check if there's data in current segment
    if head < tail:
      # Read value
      let value = seg.data[head]
      seg.head.store(head + 1, moRelaxed)
      discard self.itemCount.fetchSub(1, moRelaxed)
      return some(value)

    # Segment exhausted, try to advance
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      # Queue is empty
      return none(T)

    # Advance to next segment and free old one. Publish the advance via
    # release store so any future readers see the up-to-date head.
    let oldSeg = seg
    self.headSegment.store(nextSeg, moRelease)
    seg = nextSeg
    discard self.segments.fetchSub(1, moRelaxed)
    c_free(oldSeg)

proc pop*[S: static int, T](
    self: var UnboundedSipsic[S, T], count: int
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
      # `c_free`'s away the segment block — otherwise their internal
      # allocations leak.
      for i in 0 ..< S:
        reset(seg.data[i])
    c_free(seg)
    seg = next
