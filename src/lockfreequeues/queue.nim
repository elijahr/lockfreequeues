## Unbounded `Queue` generic — v5.0.0 final shape.
##
## Step 3.3.11-B (sub-dispatch B.2.5) reshaped the legacy unified
## `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]` (10
## params) into this 6-param unbounded-only form:
##
##     Queue[T, ccProd, ccCons, ST, S, MaxThreads]
##
## Param order is LOAD-BEARING:
##   T, ccProd, ccCons, ST, S, MaxThreads
##
## The bounded surface moved to `bqueue.nim` (`BQueue[T, ccProd, ccCons,
## N, P, C]`) in B.1. The standalone `UnboundedSipsic[S, T]` from
## `unbounded_sipsic.nim` was absorbed into this `Queue` via the
## `when (ccProd, ccCons) is (ccSingle, ccSingle):` branch of the
## object body — that branch carries no debra integration (no
## `manager`, no `ownsManager`, no pin/retire wrappers) and uses the
## committed-flag-free linked-segment protocol verbatim from the
## legacy module. The other three cardinality combos (mupsic-,
## sipmuc-, mupmuc-equiv) carry debra integration unchanged.
##
## Cardinality-illegal direct-on-queue calls (multi-producer `push`
## or multi-consumer `pop` against `Queue` directly rather than via
## `QueueProducer` / `QueueConsumer`) are gated by compile-time
## `{.error.}` overloads (Bundle E, sub-dispatch B.2). The error
## messages reference the user-visible alias type names per the M5
## R9 grep gate — no `*Multi`/`*Single` leakage.

import ./strategy
import ./reclamation
import ./internal/pinscope_stub
import ./internal/aligned_alloc
import ./internal/shared
import ./atomic_dsl
import ./backoff
import options
import std/typetraits

import ./exceptions

# nim-debra 0.8.0 surface — used for non-sipsic cardinality combos only.
# The `(ccSingle, ccSingle)` branch is debra-free (committed-flag-free
# linked-segment protocol absorbed from the standalone `UnboundedSipsic`
# type). The import set is intentionally maintained for the other three
# cardinalities; Nim's dead-code elimination strips the unused symbols
# from the sipsic-only instantiation.
from debra import
  DebraManager, ThreadHandle, PinnedScope, Destructor, initDebraManager, registerThread,
  bindClient, unbindClient, unpinned, pinScope, advanceEvery, reclaimNow

from debra import retireOnCAS, retireOnPublish

export exceptions

# `stManual`, `stEager`, `ccSingle`, `ccMulti` travel with their enum
# type; any module that imports `queue` sees them. The `rkNone` / `rkEbr`
# enum members are no longer needed by `Queue` itself (the reclamation
# axis was eliminated in 3.3.11-B), but the enum is re-exported for
# bench-adapter / migration-shim compatibility.
export
  DeallocationStrategy, ReclamationKind, PinScopeCardinality, Manual, Eager,
  DefaultDeallocationStrategy

# `NoSlice` lives in `internal/shared.nim` post-3.3.11-B.2.5. Re-exported
# here so existing callers that consume it via `lockfreequeues/queue`
# continue to compile.
export NoSlice

const LockFreeQueuesAdvanceEvery* {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in the rkEbr Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

type
  Segment*[T; ccProd, ccCons: static PinScopeCardinality, S: static int] = object
    ## Unbounded-queue segment. One linked-segment payload, parameterized
    ## by `(ccProd, ccCons)` so each cardinality variant's field set
    ## matches its per-family analogue.
    ##
    ## Field set:
    ##   - `data: array[S, T]` — slot storage (all variants).
    ##   - `next: Atomic[ptr Segment[...]]` — linked-list pointer.
    ##   - `tail: Atomic[int]` — producer write index. Atomic for
    ##     multi-producer coordination and for sipsic-equiv (publish
    ##     via release).
    ##   - `head: int` — single-consumer non-atomic read position.
    ##     Present on `(ccProd × ccSingle)` shapes (mupsic-equiv and
    ##     the absorbed sipsic-equiv). Only the single consumer ever
    ##     writes it.
    ##   - `committed: array[S, Atomic[bool]]` — multi-producer
    ##     publication flags. Present on `ccProd == ccMulti`.
    ##   - `prevConsumerIdx: Atomic[int]` — multi-consumer CAS slot.
    ##     Present on `ccCons == ccMulti`.
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    when ccCons == ccSingle:
      # mupsic-equiv + absorbed sipsic-equiv: single-consumer
      # non-atomic read position.
      head* {.align: CacheLineBytes.}: int
    when ccProd == ccMulti:
      # mupsic-equiv + mupmuc-equiv: multi-producer publication flags.
      committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
    when ccCons == ccMulti:
      # sipmuc-equiv + mupmuc-equiv: multi-consumer CAS coordination.
      prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]

  Queue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] = object
    ## Unbounded lock-free queue, parameterized by producer/consumer
    ## cardinality, deallocation strategy `ST`, segment size `S`, and
    ## the debra registry capacity `MaxThreads`.
    ##
    ## Body layout splits on `(ccProd, ccCons) is (ccSingle, ccSingle)`:
    ##
    ##   - **sipsic-absorbed** (ccSingle × ccSingle): no debra
    ##     integration. Linked-segment with committed-flag-free
    ##     SPSC protocol absorbed verbatim from the legacy
    ##     `UnboundedSipsic[S, T]` type. `MaxThreads` is a type-uniform
    ##     phantom — no thread-registry capacity is consumed.
    ##   - **non-sipsic** (mupsic-/sipmuc-/mupmuc-equiv): debra-
    ##     integrated. Owns `manager`, walks pin/retire chains in
    ##     `push`/`pop`. `MaxThreads` sizes the debra registry.
    when ccProd == ccSingle and ccCons == ccSingle:
      # Absorbed `UnboundedSipsic` body — no manager, no debra.
      headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      tailSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      itemCount*: Atomic[int]
      segments*: Atomic[int]
    else:
      # Debra-integrated body. Manager CC is gated on `ccCons`
      # (Step 3.3.4.5 soundness fix): nim-debra `cardinality.nim`
      # REQUIRES `ccMulti` for consumer pins on multi-consumer queues.
      when ccCons == ccMulti:
        manager*: ptr DebraManager[MaxThreads, debra.ccMulti]
      else:
        manager*: ptr DebraManager[MaxThreads, debra.ccSingle]
      headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      tailSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      itemCount*: Atomic[int]
      segments*: Atomic[int]
      ownsManager*: bool
      when ccProd == ccMulti:
        producerCount*: Atomic[int]
      when ccCons == ccMulti:
        consumerCount*: Atomic[int]
      when ccProd == ccMulti and ccCons == ccSingle:
        handle*: ThreadHandle[MaxThreads, debra.ccSingle]
      when ccCons == ccMulti:
        consumerHeads*: array[MaxThreads, Atomic[int]]

## ----------------------------------------------------------------------
## Param-coherence guards — unbounded subset of legacy Doc C §3.0.2.4.
##
## The legacy 9 guards covered both rkNone (6 guards) and rkEbr (3
## guards). The 6 rkNone guards moved to `bqueue.nim`
## (`assertBQueueParams`); the 3 rkEbr guards remain here.
## ----------------------------------------------------------------------

template assertQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
]() =
  static:
    assert S > 0, "Queue requires S > 0 (segment slot count)"
  static:
    assert MaxThreads > 0,
      "Queue requires MaxThreads > 0 (debra thread-registry capacity)"

proc validateQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](_: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]]) =
  ## Compile-time entry point for the 2 param-coherence guards. Has no
  ## runtime cost.
  assertQueueParams[T, ccProd, ccCons, ST, S, MaxThreads]()
  discard

type
  QueueProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] = object
    ## Per-thread producer handle for an unbounded `Queue`. Retrieved
    ## via `Queue.getProducer()`. Defined for every (ccProd, ccCons)
    ## shape for type uniformity.
    ##
    ## For `ccProd == ccMulti` the producer carries a
    ## `ThreadHandle[MaxThreads, ...]` for the pin/unpin cycle in
    ## `push`. For `ccProd == ccSingle` the producer carries no
    ## handle (sipsic/sipmuc-equiv have no pin requirement on push).
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, S, MaxThreads]
    when ccProd == ccMulti:
      # Producer.handle CC follows the manager (Step 3.3.4.5).
      when ccCons == ccMulti:
        handle*: ThreadHandle[MaxThreads, debra.ccMulti]
      else:
        handle*: ThreadHandle[MaxThreads, debra.ccSingle]

  QueueConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] = object
    ## Per-thread consumer handle for an unbounded `Queue`. Retrieved
    ## via `Queue.getConsumer()`. Defined for every (ccProd, ccCons)
    ## shape for type uniformity; only meaningful when
    ## `ccCons == ccMulti` (single-consumer cardinalities pop directly
    ## through `Queue.pop`).
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, S, MaxThreads]
    when ccCons == ccMulti:
      handle*: ThreadHandle[MaxThreads, debra.ccMulti]

## ----------------------------------------------------------------------
## Unbounded-queue body — Track E (Steps 3.3.2-3.3.4), absorbed sipsic
## from `unbounded_sipsic.nim` (B.2.5).
## ----------------------------------------------------------------------

proc newSegment[T; ccProd, ccCons: static PinScopeCardinality, S: static int](): ptr Segment[
  T, ccProd, ccCons, S
] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## `{.align.}` pragmas on `next` / `tail` / `committed` /
  ## `prevConsumerIdx` land on distinct physical cache lines.
  result = allocAligned[Segment[T, ccProd, ccCons, S]]()
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  when ccCons == ccSingle:
    # mupsic-equiv + absorbed sipsic-equiv carry a `head: int` field.
    result.head = 0
  when ccProd == ccMulti:
    for i in 0 ..< S:
      result.committed[i].store(false, moRelaxed)
  when ccCons == ccMulti:
    result.prevConsumerIdx.store(-1, moRelaxed)

## ----------------------------------------------------------------------
## Per-queue retire wrappers — Doc C §3.0.2 + γ guard.
##
## Defined only for non-sipsic cardinalities (debra-integrated). Sipsic-
## absorbed (`(ccSingle, ccSingle)`) has no debra integration and thus
## no retire-bearing site; UFCS lookup of `q.retireOn*` on a sipsic
## queue fails with method-not-defined, which is the desired guard.
##
## `retireOnCAS` is callable under any consumer cardinality (DR-S3).
## `retireOnPublish` is additionally gated on `ccCons == ccSingle`
## (DR-S4 single-writer foot-gun). The sipsic exclusion is also
## structurally enforced: sipsic's `(ccCons == ccSingle)` could match
## `retireOnPublish`'s gate, but the receiver `var Queue[..., ccSingle,
## ccSingle, ...]` body lacks the segment-pointer atomics the wrapper
## consumes — the guard fires before any harm is done, and the
## documented design is that sipsic is debra-free.
## ----------------------------------------------------------------------

proc retireOnCAS*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    CC: static debra.PinScopeCardinality,
    S, MaxThreads: static int,
    U;
](
    q: var Queue[T, ccProd, ccCons, ST, S, MaxThreads],
    scope: var PinnedScope[MaxThreads, CC],
    atomic: var Atomic[U],
    expected, desired: U,
    dtor: Destructor,
): bool {.discardable.} =
  ## Per-queue `retireOnCAS` wrapper. Delegates to nim-debra's
  ## `pinned_scope.retireOnCAS`.
  discard q
  scope.retireOnCAS(atomic, expected, desired, dtor)

proc retireOnPublish*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    CC: static debra.PinScopeCardinality,
    S, MaxThreads: static int,
    U;
](
    q: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads],
    scope: var PinnedScope[MaxThreads, CC],
    atomic: var Atomic[U],
    desired: U,
    dtor: Destructor,
) =
  ## Per-queue `retireOnPublish` wrapper. **FOOT-GUN — single-writer
  ## required (DR-S4).** Delegates to nim-debra's
  ## `pinned_scope.retireOnPublish`.
  discard q
  scope.retireOnPublish(atomic, desired, dtor)

# ---------------------------------------------------------------------
# Segment destructor — monomorphic-per-(T, ccProd, ccCons, S).
# ---------------------------------------------------------------------

proc segmentDestructor[T; ccProd, ccCons: static PinScopeCardinality, S: static int](
    p: pointer
) {.nimcall, raises: [].} =
  when not supportsCopyMem(T):
    let seg = cast[ptr Segment[T, ccProd, ccCons, S]](p)
    for i in 0 ..< S:
      reset(seg.data[i])
  freeAligned(p)

## ----------------------------------------------------------------------
## Constructors.
##
## Three overloads, distinguished by signature:
##   1. **typedesc-only** — auto-create. Allocates a manager internally
##      (non-sipsic) or just initializes the body (sipsic). Works for
##      all 4 cardinality combos.
##   2. **typedesc + manager + handle** — manager-borrowed for
##      ccCons==ccSingle. The handle is consumed by mupsic-equiv only.
##   3. **typedesc + manager** — manager-borrowed for ccCons==ccMulti.
##
## A 4th overload `{.error.}`-gates the manager-borrowed signature on
## sipsic-absorbed (`(ccSingle, ccSingle)`) since debra is not used
## there.
## ----------------------------------------------------------------------

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, debra.ccSingle],
    handle: ThreadHandle[MaxThreads, debra.ccSingle],
): Queue[T, ccProd, ccSingle, ST, S, MaxThreads] =
  ## Manager-borrowed unbounded `newQueue` overload — ccCons == ccSingle
  ## variants (mupsic-equiv only; the sipsic-absorbed `(ccSingle,
  ## ccSingle)` shape is debra-free and uses a separate `{.error.}`
  ## overload below).
  ##
  ## Caller owns the `DebraManager`. Sets `ownsManager = false`. The
  ## handle is consumed by mupsic-equiv (`ccProd == ccMulti`) and stored
  ## on the queue. ccProd-ccSingle sipsic-equiv would be type-uniformly
  ## constructable here, but is excluded by the dedicated sipsic
  ## `{.error.}` overload further below.
  validateQueueParams(Queue[T, ccProd, ccSingle, ST, S, MaxThreads])
  # ccProd == ccSingle here means sipsic-absorbed, which is debra-free
  # and routes through the dedicated `{.error.}` overload below — so by
  # the time we reach this body, ccProd is effectively ccMulti
  # (mupsic-equiv).
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
    result.handle = handle
  else:
    discard handle
  let seg = newSegment[T, ccProd, ccSingle, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccMulti, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, debra.ccMulti],
    handle: ThreadHandle[MaxThreads, debra.ccMulti],
): Queue[T, ccProd, ccMulti, ST, S, MaxThreads] =
  ## Manager-borrowed unbounded `newQueue` overload — ccCons == ccMulti
  ## variants (sipmuc-equiv + mupmuc-equiv).
  validateQueueParams(Queue[T, ccProd, ccMulti, ST, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)
  discard handle
  let seg = newSegment[T, ccProd, ccMulti, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

proc newQueue*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccMulti, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, debra.ccMulti],
): Queue[T, ccProd, ccMulti, ST, S, MaxThreads] =
  ## Handle-free manager-borrowed unbounded `newQueue` overload for
  ## ccCons == ccMulti (sipmuc-equiv and mupmuc-equiv).
  validateQueueParams(Queue[T, ccProd, ccMulti, ST, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)
  let seg = newSegment[T, ccProd, ccMulti, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

# Sipsic-absorbed manager-borrowed `{.error.}` gate. The sipsic-absorbed
# `(ccSingle, ccSingle)` body is debra-free; routing through a borrow
# overload would mis-shape the body. M5 R9: error string references
# user-visible alias names only.
proc newQueue*[
    T;
    ST: static DeallocationStrategy,
    CC: static debra.PinScopeCardinality,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, CC],
    handle: ThreadHandle[MaxThreads, CC],
): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.error:
    "Sipsic-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
    "Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) " &
    "overload instead.".} =
  discard

proc newQueue*[
    T;
    ST: static DeallocationStrategy,
    CC: static debra.PinScopeCardinality,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, CC],
): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.error:
    "Sipsic-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
    "Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) " &
    "overload instead.".} =
  discard

proc newQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccCons, ST, S, MaxThreads]]
): Queue[T, ccProd, ccCons, ST, S, MaxThreads] =
  ## Auto-create unbounded `newQueue` overload. For the sipsic-absorbed
  ## `(ccSingle, ccSingle)` branch this skips manager allocation
  ## entirely. For the other three cardinality combos, allocates a
  ## private `DebraManager[MaxThreads, ...]`, registers the calling
  ## thread, and sets `ownsManager = true`.
  ##
  ## **Caller must be the consumer thread for mupsic-equiv** —
  ## constructing on a different thread than the future `pop` caller
  ## would mis-route the consumer handle.
  validateQueueParams(Queue[T, ccProd, ccCons, ST, S, MaxThreads])
  when ccProd == ccSingle and ccCons == ccSingle:
    # Sipsic-absorbed: no manager, no debra. Allocate initial segment
    # and zero the counters; that's it.
    let seg = newSegment[T, ccSingle, ccSingle, S]()
    result.headSegment.store(seg, moRelaxed)
    result.tailSegment.store(seg, moRelaxed)
    result.itemCount.store(0, moRelaxed)
    result.segments.store(1, moRelaxed)
  else:
    when ccCons == ccMulti:
      let mgr = allocAligned[DebraManager[MaxThreads, debra.ccMulti]]()
    else:
      let mgr = allocAligned[DebraManager[MaxThreads, debra.ccSingle]]()
    var ok = false
    try:
      when ccCons == ccMulti:
        mgr[] = initDebraManager[MaxThreads, debra.ccMulti]()
      else:
        mgr[] = initDebraManager[MaxThreads, debra.ccSingle]()
      let consumerHandle = registerThread(mgr[])
      result =
        newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads], mgr, consumerHandle)
      result.ownsManager = true
      ok = true
    finally:
      if not ok:
        reset(mgr[])
        freeAligned(mgr)

proc getProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
): QueueProducer[T, ccProd, ccCons, ST, S, MaxThreads] =
  ## Returns a `QueueProducer` view bound to this queue. For
  ## `ccProd == ccMulti` registers the calling thread against the
  ## queue's `DebraManager` and stores the resulting `ThreadHandle`
  ## on the producer view.
  result.queue = addr(self)
  when ccProd == ccMulti:
    let idx = self.producerCount.fetchAdd(1, moAcquire)
    result.idx = idx
    result.handle = registerThread(self.manager[])
  else:
    result.idx = -1

proc getConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
): QueueConsumer[T, ccProd, ccCons, ST, S, MaxThreads] =
  ## Returns a `QueueConsumer` view bound to this queue. For
  ## `ccCons == ccMulti` registers the calling thread against the
  ## queue's `DebraManager`.
  result.queue = addr(self)
  when ccCons == ccMulti:
    let idx = self.consumerCount.fetchAdd(1, moAcquire)
    result.idx = idx
    result.handle = registerThread(self.manager[])
  else:
    result.idx = -1

## ----------------------------------------------------------------------
## len / segmentCount accessors.
## ----------------------------------------------------------------------

proc len*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): int =
  ## Number of items currently in the queue (atomic snapshot).
  result = self.itemCount.load(moRelaxed)

proc segmentCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): int =
  ## Number of segments currently allocated (atomic snapshot).
  result = self.segments.load(moRelaxed)

## ----------------------------------------------------------------------
## Push body — single-item.
##
## Per-cardinality dispatch via `when (ccProd, ccCons) is`:
##   - sipsic-absorbed (ccSingle × ccSingle): no pin, no committed-flag;
##     simple tail/`next` linked-segment advance. Lifted verbatim from
##     the legacy `unbounded_sipsic.nim` push.
##   - sipmuc-equiv (ccSingle × ccMulti): no pin (single producer),
##     simple tail advance.
##   - mupsic/mupmuc-equiv (ccMulti × _): pin via
##     `pinScope(unpinned(self.handle))`, CAS slot claim with segment
##     growth on full.
## ----------------------------------------------------------------------

proc push*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueProducer[T, ccProd, ccCons, ST, S, MaxThreads],
    item: T,
) {.raises: [].} =
  ## Push a single item onto the unbounded queue (cardinality-dispatched).
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  when ccProd == ccSingle and ccCons == ccSingle:
    # Sipsic-absorbed — no pin, no committed flag, no debra.
    # Lifted verbatim from `unbounded_sipsic.nim:83-115`.
    var seg = self.queue.tailSegment.load(moRelaxed)
    let tail = seg.tail.load(moRelaxed)
    if tail >= S:
      let newSeg = newSegment[T, ccProd, ccCons, S]()
      seg.next.store(newSeg, moRelease)
      self.queue.tailSegment.store(newSeg, moRelease)
      seg = newSeg
      discard self.queue.segments.fetchAdd(1, moRelaxed)
    let pos = seg.tail.load(moRelaxed)
    seg.data[pos] = item
    seg.tail.store(pos + 1, moRelease)
    discard self.queue.itemCount.fetchAdd(1, moRelaxed)
  elif ccProd == ccSingle and ccCons == ccMulti:
    # sipmuc-equiv — no pin (single producer).
    var seg = self.queue.tailSegment.load(moRelaxed)
    var tail = seg.tail.load(moRelaxed)
    if tail >= S:
      let newSeg = newSegment[T, ccProd, ccCons, S]()
      seg.next.store(newSeg, moRelease)
      self.queue.tailSegment.store(newSeg, moRelease)
      seg = newSeg
      tail = 0
      discard self.queue.segments.fetchAdd(1, moRelaxed)
    seg.data[tail] = item
    seg.tail.store(tail + 1, moRelease)
    discard self.queue.itemCount.fetchAdd(1, moRelaxed)
  else:
    # ccProd == ccMulti — mupsic-equiv + mupmuc-equiv share the push
    # body shape (the cardinality difference is on the consumer side).
    # §3.5.6 Pin-Claim Ordering: `pinScope` MUST be acquired BEFORE
    # the first `tailSegment.load(...)`.
    block:
      var scope {.used.} = pinScope(unpinned(self.handle))
      var spins = InitialSpin
      while true:
        var seg = self.queue.tailSegment.load(moAcquire)
        var tail = seg.tail.load(moAcquire)
        if tail >= S:
          let nextSeg = seg.next.load(moAcquire)
          if nextSeg == nil:
            let newSeg = newSegment[T, ccProd, ccCons, S]()
            var expectedNext: ptr Segment[T, ccProd, ccCons, S] = nil
            if seg.next.compareExchange(expectedNext, newSeg, moRelease, moRelaxed):
              var expectedSeg = seg
              discard self.queue.tailSegment.compareExchange(
                expectedSeg, newSeg, moRelease, moRelaxed
              )
              discard self.queue.segments.fetchAdd(1, moRelaxed)
              continue
            else:
              freeAligned(newSeg)
              backoffOnRetry(spins)
              continue
          else:
            var expectedSeg = seg
            discard self.queue.tailSegment.compareExchange(
              expectedSeg, nextSeg, moRelease, moRelaxed
            )
            continue
        var expected = tail
        if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
          seg.data[tail] = item
          seg.committed[tail].store(true, moRelease)
          discard self.queue.itemCount.fetchAdd(1, moRelaxed)
          break

# Batch push for all 4 cardinality combos — thin loop.
proc push*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueProducer[T, ccProd, ccCons, ST, S, MaxThreads],
    items: openArray[T],
) {.raises: [].} =
  ## Batch push for unbounded `Queue`. Thin loop over single-item push.
  for item in items:
    self.push(item)

## ----------------------------------------------------------------------
## Pop body — single-item.
##
## Doc C §3.5 carrier decision: pop lives on bare `Queue` for
## ccCons == ccSingle variants (sipsic-absorbed + mupsic-equiv) and on
## `QueueConsumer` for ccCons == ccMulti variants (sipmuc-equiv,
## mupmuc-equiv).
## ----------------------------------------------------------------------

# --- sipsic-absorbed pop (ccSingle × ccSingle, direct on Queue, no pin) -----
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
): Option[T] =
  ## Sipsic-absorbed pop — direct slot read + segment advance with
  ## `freeAligned(oldSeg)`. No pin (no retire-race; only one consumer
  ## ever runs, only one producer ever writes). Lifted verbatim from
  ## `unbounded_sipsic.nim:122-166`.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  var seg = self.headSegment.load(moAcquire)
  while true:
    let head = seg.head
    let tail = seg.tail.load(moAcquire)
    if head < tail:
      let value = seg.data[head]
      seg.head = head + 1
      discard self.itemCount.fetchSub(1, moRelaxed)
      return some(value)
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      return none(T)
    let oldSeg = seg
    self.headSegment.store(nextSeg, moRelease)
    seg = nextSeg
    discard self.segments.fetchSub(1, moRelaxed)
    freeAligned(oldSeg)

# --- mupsic-equiv pop (ccMulti × ccSingle, direct on Queue, retireOnPublish) -
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]
): Option[T] =
  ## mupsic-equiv pop — §3.5.1 retire-bearing site.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  block:
    var scope = pinScope(unpinned(self.handle))
    var seg = self.headSegment.load(moAcquire)
    while true:
      let tail = seg.tail.load(moAcquire)
      if seg.head < tail:
        if seg.committed[seg.head].load(moAcquire):
          result = some(seg.data[seg.head])
          inc seg.head
          discard self.itemCount.fetchSub(1, moRelaxed)
        break
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        break
      self.retireOnPublish(
        scope, self.headSegment, nextSeg, segmentDestructor[T, ccMulti, ccSingle, S]
      )
      when ST != stManual:
        discard self.segments.fetchSub(1, moRelaxed)
      seg = nextSeg

  when ST == stEager:
    if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(self.handle)

# --- batch pop (ccCons == ccSingle, direct on Queue) ----------------------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads], count: int
): Option[seq[T]] =
  ## Batch pop for ccCons == ccSingle. Thin loop over single-item pop.
  if unlikely(count <= 0):
    return none(seq[T])
  var items = newSeqOfCap[T](count)
  for _ in 0 ..< count:
    let v = self.pop()
    if v.isNone:
      break
    items.add(v.get)
  if items.len == 0:
    none(seq[T])
  else:
    some(items)

# --- sipmuc-equiv pop (ccSingle × ccMulti, via QueueConsumer, retireOnCAS) -
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var QueueConsumer[T, ccSingle, ccMulti, ST, S, MaxThreads]
): Option[T] =
  ## sipmuc-equiv pop — §3.5.3 retire-bearing site.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  block:
    var scope = pinScope(unpinned(self.handle))
    var seg = self.queue.headSegment.load(moAcquire)
    var spins = InitialSpin
    while true:
      let tail = seg.tail.load(moAcquire)
      var prevIdx = seg.prevConsumerIdx.load(moAcquire)
      let mySlot = prevIdx + 1
      if mySlot >= tail:
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break
        if self.queue[].retireOnCAS(
          scope,
          self.queue.headSegment,
          seg,
          nextSeg,
          segmentDestructor[T, ccSingle, ccMulti, S],
        ):
          when ST != stManual:
            discard self.queue.segments.fetchSub(1, moRelaxed)
          seg = nextSeg
        else:
          seg = self.queue.headSegment.load(moAcquire)
        backoffOnRetry(spins)
        continue

      if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
        result = some(seg.data[mySlot])
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        break

  when ST == stEager:
    if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(self.handle)

# --- mupmuc-equiv pop (ccMulti × ccMulti, via QueueConsumer, retireOnCAS) -
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var QueueConsumer[T, ccMulti, ccMulti, ST, S, MaxThreads]
): Option[T] =
  ## mupmuc-equiv pop — §3.5.2 retire-bearing site.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "Queue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  block:
    var scope = pinScope(unpinned(self.handle))
    var seg = self.queue.headSegment.load(moAcquire)
    var spins = InitialSpin
    while true:
      let tail = seg.tail.load(moAcquire)
      var prevIdx = seg.prevConsumerIdx.load(moAcquire)
      let mySlot = prevIdx + 1
      if mySlot >= tail:
        if mySlot < S and seg.tail.load(moAcquire) > mySlot:
          if not seg.committed[mySlot].load(moAcquire):
            break
          backoffOnRetry(spins)
          continue
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break
        if self.queue[].retireOnCAS(
          scope,
          self.queue.headSegment,
          seg,
          nextSeg,
          segmentDestructor[T, ccMulti, ccMulti, S],
        ):
          when ST != stManual:
            discard self.queue.segments.fetchSub(1, moRelaxed)
          seg = nextSeg
        else:
          seg = self.queue.headSegment.load(moAcquire)
        backoffOnRetry(spins)
        continue
      if not seg.committed[mySlot].load(moAcquire):
        break # Producer still writing
      if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
        result = some(seg.data[mySlot])
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        break

  when ST == stEager:
    if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(self.handle)

# --- batch pop (ccCons == ccMulti, via QueueConsumer) --------------------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueConsumer[T, ccProd, ccMulti, ST, S, MaxThreads],
    count: int,
): Option[seq[T]] =
  ## Batch pop for ccCons == ccMulti. Thin loop over single-item pop.
  if unlikely(count <= 0):
    return none(seq[T])
  var items = newSeqOfCap[T](count)
  for _ in 0 ..< count:
    let v = self.pop()
    if v.isNone:
      break
    items.add(v.get)
  if items.len == 0:
    none(seq[T])
  else:
    some(items)

# --- ccMulti-consumer compile-time gate on bare Queue.pop ----------------
# Bundle E: compile-time `{.error.}` overload. References user-visible
# alias name `QueueConsumer` per M5 R9.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccMulti, ST, S, MaxThreads]): Option[T] {.error:
    "Direct pop on a multi-consumer Queue is not allowed. " &
    "Use Queue.getConsumer().pop() to obtain a per-thread " &
    "QueueConsumer and pop through it.".} =
  discard

# --- ccMulti-consumer compile-time gate on bare Queue batch pop ----------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, S, MaxThreads], count: int
): Option[seq[T]] {.error:
    "Direct batch pop on a multi-consumer Queue is not allowed. " &
    "Use Queue.getConsumer().pop(count) to obtain a per-thread " &
    "QueueConsumer and batch-pop through it.".} =
  discard

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]) =
  ## Destructor. Walks `headSegment` → `next` → ... freeing each
  ## segment. For non-sipsic cardinalities, additionally unbinds the
  ## client refcount on the manager and (when `ownsManager`) runs the
  ## manager's destructor.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    let nextSeg = seg.next.load(moRelaxed)
    when not supportsCopyMem(T):
      for i in 0 ..< S:
        reset(seg.data[i])
    freeAligned(seg)
    seg = nextSeg

  when not (ccProd == ccSingle and ccCons == ccSingle):
    if self.manager != nil:
      unbindClient(self.manager[])
      if self.ownsManager:
        reset(self.manager[])
        freeAligned(self.manager)

## ----------------------------------------------------------------------
## Family-named unbounded smart constructors (Bundle D — kept as thin
## wrappers per the B.2 coord note's recommended path (b) to minimize
## test churn).
##
## M4 alias-return lock honored — every signature returns
## `Queue[...]`, never a backing type.
## ----------------------------------------------------------------------

proc newUnboundedSipsicQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded sipsic-absorbed (`ccSingle × ccSingle`) auto-create
  ## smart-constructor. Skips manager allocation (sipsic-absorbed has
  ## no debra integration). Added in B.2.5 alongside the absorption.
  newQueue(Queue[T, ccSingle, ccSingle, ST, S, MaxThreads])

proc newUnboundedMupsicQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccSingle],
    consumerHandle: ThreadHandle[MaxThreads, debra.ccSingle],
): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mupsic-equivalent (`ccMulti × ccSingle`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads], manager, consumerHandle)

proc newUnboundedMupsicQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mupsic-equivalent (`ccMulti × ccSingle`) auto-create
  ## smart-constructor. **Caller must be the consumer thread** —
  ## constructing on a different thread mis-routes the consumer
  ## handle.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads])

proc newUnboundedSipmucQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccMulti]
): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded sipmuc-equivalent (`ccSingle × ccMulti`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccSingle, ccMulti, ST, S, MaxThreads], manager)

proc newUnboundedSipmucQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded sipmuc-equivalent (`ccSingle × ccMulti`) auto-create
  ## smart-constructor.
  newQueue(Queue[T, ccSingle, ccMulti, ST, S, MaxThreads])

proc newUnboundedMupmucQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccMulti]
): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mupmuc-equivalent (`ccMulti × ccMulti`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccMulti, ST, S, MaxThreads], manager)

proc newUnboundedMupmucQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mupmuc-equivalent (`ccMulti × ccMulti`) auto-create
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccMulti, ST, S, MaxThreads])

## ----------------------------------------------------------------------
## Test-only introspection helpers for the unbounded Segment layout.
## ----------------------------------------------------------------------

when defined(testing):
  proc headSegmentForTest*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]): pointer =
    ## Test-only accessor: returns the queue's current head-segment
    ## pointer so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentTailOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of the cache-line-padded `tail`
    ## field within the unified Segment for any cardinality.
    offsetOf(Segment[T, ccProd, ccCons, S], tail)

  proc segmentHeadOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `head` for cardinality
    ## combos that carry it (`ccCons == ccSingle`). For shapes that
    ## lack `head` Nim's `offsetOf` will compile-fail at the call site.
    offsetOf(Segment[T, ccProd, ccCons, S], head)

  proc segmentCommittedOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `committed` for cardinality
    ## combos that carry it (`ccProd == ccMulti`).
    offsetOf(Segment[T, ccProd, ccCons, S], committed)

  proc segmentPrevConsumerIdxOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `prevConsumerIdx` for
    ## cardinality combos that carry it (`ccCons == ccMulti`).
    offsetOf(Segment[T, ccProd, ccCons, S], prevConsumerIdx)
