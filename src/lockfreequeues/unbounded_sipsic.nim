## Unbounded single-producer, single-consumer (SPSC) queue using linked segments.
##
## Uses direct memory management (alloc0/dealloc). No DEBRA needed for SPSC.
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
import std/options

type
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr Segment[S, T]]
    head*: Atomic[int]
    tail*: Atomic[int]

  UnboundedSipsic*[S: static int, T] = object
    ## Unbounded SPSC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    headSegment: ptr Segment[S, T] # Consumer reads from here
    tailSegment: ptr Segment[S, T] # Producer writes here
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment using Nim's alloc0 (zero-initialized).
  result = cast[ptr Segment[S, T]](alloc0(sizeof(Segment[S, T])))
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
            "On arc/orc, ref types use spinlock-based atomic operations for reference counting. " &
            "Use a lock-free type (int, pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow spinlock fallback."
        .}

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment = seg
  result.tailSegment = seg
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
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  var seg = self.tailSegment

  # Check if current segment is full
  let tail = seg.tail.load(moRelaxed)
  if tail >= S:
    # Allocate new segment
    let newSeg = newSegment[S, T]()
    seg.next.store(newSeg, moRelease)
    self.tailSegment = newSeg
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
            "Use -d:allowNonLockFreeQueueItems to allow."
        .}

  var seg = self.headSegment

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

    # Advance to next segment and free old one
    let oldSeg = seg
    self.headSegment = nextSeg
    seg = nextSeg
    discard self.segments.fetchSub(1, moRelaxed)
    dealloc(oldSeg)

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

proc `=destroy`*[S: static int, T](self: var UnboundedSipsic[S, T]) =
  ## Clean up all segments.
  if self.headSegment != nil:
    var seg = self.headSegment
    while seg != nil:
      let next = seg.next.load(moRelaxed)
      dealloc(seg)
      seg = next
