## Backwards-compatibility adapter for `lockfreequeues` v4.2.0.
##
## This module provides a zero-breakage drop-in replacement for legacy code
## written against `lockfreequeues`, backed by the modern `lockfree` package.
## It maps legacy types and constructors onto the unified `BQueue` and `Queue`
## engines while preserving historical generic parameter ordering, constructor
## arities, and implicit thread registration semantics.

import options
import lockfree/atomics
import lockfree/atomics/dsl
import lockfree/strategy
import lockfree/cardinality
import lockfree/exceptions
import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/smr/nebr as nebr
import lockfree/smr/nebr/signal as nebr_signal
import std/typedthreads

export atomics, dsl
export strategy
export cardinality
export exceptions
export bqueue
export queue
export endpoint.Bound, endpoint.Unbound, endpoint.Closed, endpoint.EndpointClosed, endpoint.getProducerHere, endpoint.getConsumerHere, endpoint.bindToThread

const NoSlice* = none(HSlice[int, int])

# ---------------------------------------------------------------------------
# SMR legacy aliases
# ---------------------------------------------------------------------------

export nebr.DebraManager, nebr.ThreadHandle

# ---------------------------------------------------------------------------
# Bounded legacy type aliases (historical parameter ordering: capacity/threads first, T last)
# ---------------------------------------------------------------------------

type
  Sipsic*[N: static int; T] = BQueue[T, ccSingle, ccSingle, N, 0, 0]
    ## Single-producer, single-consumer (SPSC) bounded queue.

  Mupsic*[N, P: static int; T] = BQueue[T, ccMulti, ccSingle, N, P, 0]
    ## Multi-producer, single-consumer (MPSC) bounded queue.

  Sipmuc*[N, C: static int; T] = BQueue[T, ccSingle, ccMulti, N, 0, C]
    ## Single-producer, multi-consumer (SPMC) bounded queue.

  Mupmuc*[N, P, C: static int; T] = BQueue[T, ccMulti, ccMulti, N, P, C]
    ## Multi-producer, multi-consumer (MPMC) bounded queue.

  # Per-thread endpoint aliases
  MupmucProducer*[N, P, C: static int; T] = Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
  MupmucConsumer*[N, P, C: static int; T] = Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
  MupsicProducer*[N, P: static int; T] = Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccSingle, N, P, 0]]
  SipmucConsumer*[N, C: static int; T] = Bound[T, AnyThreadTag, BQueue[T, ccSingle, ccMulti, N, 0, C]]

# ---------------------------------------------------------------------------
# Unbounded legacy type aliases
# ---------------------------------------------------------------------------

type
  UnboundedSipsic*[S: static int, T] = Queue[T, ccSingle, ccSingle, stEager, S, 1]
    ## Single-producer, single-consumer (SPSC) unbounded queue.

  UnboundedMupsic*[S: static int, T; MaxThreads: static int = 64] = Queue[T, ccMulti, ccSingle, stEager, S, MaxThreads]
    ## Multi-producer, single-consumer (MPSC) unbounded queue.

  UnboundedSipmuc*[S: static int, T; MaxThreads: static int = 64] = Queue[T, ccSingle, ccMulti, stEager, S, MaxThreads]
    ## Multi-producer, multi-consumer (SPMC) unbounded queue.

  UnboundedMupmuc*[S: static int, T; MaxThreads: static int = 64] = Queue[T, ccMulti, ccMulti, stEager, S, MaxThreads]
    ## Multi-producer, multi-consumer (MPMC) unbounded queue.

  # Modern-style Queue alias wrappers with T first
  UnboundedSipsicQueue*[T; S: static int] = Queue[T, ccSingle, ccSingle, stEager, S, 1]
  UnboundedMupsicQueue*[T; S, MaxThreads: static int] = Queue[T, ccMulti, ccSingle, stEager, S, MaxThreads]
  UnboundedSipmucQueue*[T; S, MaxThreads: static int] = Queue[T, ccSingle, ccMulti, stEager, S, MaxThreads]
  UnboundedMupmucQueue*[T; S, MaxThreads: static int] = Queue[T, ccMulti, ccMulti, stEager, S, MaxThreads]

# ---------------------------------------------------------------------------
# Bounded constructors (supporting both minimal and 4-param arities)
# ---------------------------------------------------------------------------

template newSipsicQueue*[T; N: static int; P: static int = 0; C: static int = 0](): untyped =
  newBQueue[T, ccSingle, ccSingle, N, 0, 0]()

template newMupsicQueue*[T; N, P: static int; C: static int = 0](): untyped =
  newBQueue[T, ccMulti, ccSingle, N, P, 0]()

template newSipmucQueue*[T; N, C: static int](): untyped =
  newBQueue[T, ccSingle, ccMulti, N, 0, C]()

template newMupmucQueue*[T; N, P, C: static int](): untyped =
  newBQueue[T, ccMulti, ccMulti, N, P, C]()

# Legacy init* constructors (capacity first, T last)
proc initSipsic*[N: static int, T](): Sipsic[N, T] {.inline.} =
  newBQueue[T, ccSingle, ccSingle, N, 0, 0]()

proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] {.inline.} =
  newBQueue[T, ccMulti, ccSingle, N, P, 0]()

proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T] {.inline.} =
  newBQueue[T, ccSingle, ccMulti, N, 0, C]()

proc initMupmuc*[N, P, C: static int, T](): Mupmuc[N, P, C, T] {.inline.} =
  newBQueue[T, ccMulti, ccMulti, N, P, C]()

# ---------------------------------------------------------------------------
# Unbounded constructors
# ---------------------------------------------------------------------------

# newUnbounded*Queue constructors (T first)
template newUnboundedSipsicQueue*[T; S: static int](): untyped =
  newQueue(Queue[T, ccSingle, ccSingle, stEager, S, 1])

template newUnboundedMupsicQueue*[T; S, MaxThreads: static int](): untyped =
  newQueue(Queue[T, ccMulti, ccSingle, stEager, S, MaxThreads])

template newUnboundedSipmucQueue*[T; S, MaxThreads: static int](): untyped =
  newQueue(Queue[T, ccSingle, ccMulti, stEager, S, MaxThreads])

template newUnboundedMupmucQueue*[T; S, MaxThreads: static int](): untyped =
  newQueue(Queue[T, ccMulti, ccMulti, stEager, S, MaxThreads])

# Legacy newUnbounded* constructors (S first, T second)
template newUnboundedSipsic*[S: static int, T](): untyped =
  newUnboundedSpscQueue[T, stEager, S, 1]()

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int = 64](): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads]()

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int](manager: auto): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccSingle]](manager))

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int](manager: auto, handle: auto): untyped =
  newUnboundedMpscQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccSingle]](manager))

template newUnboundedMupsic*[S: static int, T; MaxThreads: static int](manager: auto, handle: auto, strategy: DeallocationStrategy): untyped =
  newUnboundedMpscQueue[T, strategy, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccSingle]](manager))

template newUnboundedSipmuc*[S: static int, T; MaxThreads: static int = 64](): untyped =
  newUnboundedSpmcQueue[T, stEager, S, MaxThreads]()

template newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](manager: auto): untyped =
  newUnboundedSpmcQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

template newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](manager: auto, strategy: DeallocationStrategy): untyped =
  newUnboundedSpmcQueue[T, strategy, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

template newUnboundedMupmuc*[S: static int, T; MaxThreads: static int = 64](): untyped =
  newUnboundedMpmcQueue[T, stEager, S, MaxThreads]()

template newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](manager: auto): untyped =
  newUnboundedMpmcQueue[T, stEager, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

template newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](manager: auto, strategy: DeallocationStrategy): untyped =
  newUnboundedMpmcQueue[T, strategy, S, MaxThreads](cast[ptr nebr.DebraManager[MaxThreads, nebr.ccMulti]](manager))

# ---------------------------------------------------------------------------
# Auto-attach logic for endpoints (DEFECT-WARN-01)
# ---------------------------------------------------------------------------

proc getOrCreateHandle*[MaxThreads: static int, CC: static nebr.PinScopeCardinality](
    mgr: ptr nebr.DebraManager[MaxThreads, CC]
): nebr.ThreadHandle[MaxThreads, CC] =
  if mgr == nil:
    return nebr.ThreadHandle[MaxThreads, CC](manager: nil, idx: -1)
  if nebr_signal.threadLocalRegistered and nebr_signal.threadLocalManager == cast[pointer](mgr):
    return nebr.ThreadHandle[MaxThreads, CC](manager: mgr, idx: nebr_signal.threadLocalIdx)
  return nebr.registerThread(mgr[])

template getProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): untyped =
  var b: Bound[T, AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
  b.queue = addr(self)
  when ccProd == ccSingle and ccCons == ccSingle:
    discard
  else:
    let h = getOrCreateHandle(self.manager)
    b.handleManager = cast[pointer](h.manager)
    b.handleIdx = h.idx
  when defined(debug):
    b.attachedTid = getThreadId()
  b

template getProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads], handle: auto): untyped =
  var b: Bound[T, AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
  b.queue = addr(self)
  when ccProd == ccSingle and ccCons == ccSingle:
    discard
  else:
    b.handleManager = cast[pointer](handle.manager)
    b.handleIdx = handle.idx
  when defined(debug):
    b.attachedTid = getThreadId()
  b

template getConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): untyped =
  var b: Bound[T, AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
  b.queue = addr(self)
  when ccProd == ccSingle and ccCons == ccSingle:
    discard
  else:
    let h = getOrCreateHandle(self.manager)
    b.handleManager = cast[pointer](h.manager)
    b.handleIdx = h.idx
  when defined(debug):
    b.attachedTid = getThreadId()
  b

template getConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads], handle: auto): untyped =
  var b: Bound[T, AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
  b.queue = addr(self)
  when ccProd == ccSingle and ccCons == ccSingle:
    discard
  else:
    b.handleManager = cast[pointer](handle.manager)
    b.handleIdx = handle.idx
  when defined(debug):
    b.attachedTid = getThreadId()
  b

template getProducer*[T; ccCons: static PinScopeCardinality, N, P, C: static int](
    self: var BQueue[T, ccMulti, ccCons, N, P, C], idx: int = -1
): untyped =
  endpoint.getProducer(self, idx).bindToThread()

template getConsumer*[T; ccProd: static PinScopeCardinality, N, P, C: static int](
    self: var BQueue[T, ccProd, ccMulti, N, P, C], idx: int = -1
): untyped =
  endpoint.getConsumer(self, idx).bindToThread()

template attach*(b: Bound): untyped = b
template attach*(u: Unbound): untyped = u.bindToThread()

proc isAttached*[T; Tag; queueT](u: Unbound[T, Tag, queueT]): bool {.inline.} = false
proc isAttached*[T; Tag; queueT](b: Bound[T, Tag, queueT]): bool {.inline.} = true

# ---------------------------------------------------------------------------
# Accessors: empty, full
# ---------------------------------------------------------------------------

proc empty*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): bool {.inline.} =
  self.len == 0

proc full*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): bool {.inline.} =
  false

proc empty*[T; ccProd, ccCons: static PinScopeCardinality, N, P, C: static int](
    self: var BQueue[T, ccProd, ccCons, N, P, C]
): bool {.inline.} =
  when ccProd == ccSingle and ccCons == ccSingle:
    self.head.load(moAcquire) == self.tail.load(moAcquire)
  else:
    self.head.load(moAcquire) == self.tail.load(moAcquire)

proc full*[T; ccProd, ccCons: static PinScopeCardinality, N, P, C: static int](
    self: var BQueue[T, ccProd, ccCons, N, P, C]
): bool {.inline.} =
  when ccProd == ccSingle and ccCons == ccSingle:
    let h = self.head.load(moAcquire)
    let t = self.tail.load(moAcquire)
    let used = (t - h) mod (2 * (N + 1))
    used >= N
  else:
    let h = self.head.load(moAcquire)
    let t = self.tail.load(moAcquire)
    let used = int((t - h) mod uint64(2 * N))
    used >= N

# ---------------------------------------------------------------------------
# Direct pop for UnboundedMupsic (ccMulti x ccSingle)
# ---------------------------------------------------------------------------

proc pop*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]): Option[T] =
  let h = getOrCreateHandle(self.manager)
  var b: Bound[T, AnyThreadTag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]
  b.queue = addr(self)
  b.handleManager = cast[pointer](h.manager)
  b.handleIdx = h.idx
  when defined(debug):
    b.attachedTid = getThreadId()
  b.pop()

proc pop*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccMulti, ccSingle, ST, S, MaxThreads], count: int): Option[seq[T]] =
  let h = getOrCreateHandle(self.manager)
  var b: Bound[T, AnyThreadTag, Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]]
  b.queue = addr(self)
  b.handleManager = cast[pointer](h.manager)
  b.handleIdx = h.idx
  when defined(debug):
    b.attachedTid = getThreadId()
  b.pop(count)

# ---------------------------------------------------------------------------
# Direct push and pop for UnboundedSipsic (ccSingle x ccSingle)
# ---------------------------------------------------------------------------

proc push*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads], item: sink T) =
  var b: Bound[T, AnyThreadTag, Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]]
  b.queue = addr(self)
  when defined(debug):
    b.attachedTid = getThreadId()
  b.push(item)

proc push*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads], items: openArray[T]) =
  var b: Bound[T, AnyThreadTag, Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]]
  b.queue = addr(self)
  when defined(debug):
    b.attachedTid = getThreadId()
  b.push(items)

