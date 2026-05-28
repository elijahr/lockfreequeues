## Unbounded `Queue` generic.
##
##     Queue[T, ccProd, ccCons, ST, S, MaxThreads]
##
## Param order is LOAD-BEARING:
##   T, ccProd, ccCons, ST, S, MaxThreads
##
## The bounded surface lives in `bqueue.nim` (`BQueue[T, ccProd, ccCons,
## N, P, C]`). The `(ccSingle, ccSingle)` branch of the object body
## carries no debra integration (no `manager`, no `ownsManager`, no
## pin/retire wrappers) and uses the committed-flag-free linked-segment
## protocol from the legacy standalone unbounded-SPSC module. The other
## three cardinality combos (MPSC, SPMC, MPMC) carry debra integration.
##
## Cardinality-illegal direct-on-queue calls (multi-producer `push`
## or multi-consumer `pop` against `Queue` directly rather than via
## `QueueProducer` / `QueueConsumer`) are gated by compile-time
## `{.error.}` overloads. The error messages reference the user-visible
## alias type names — no `*Multi`/`*Single` leakage.

import ./strategy
import ./reclamation
import ./internal/pinscope_stub
import ./internal/aligned_alloc
import ./internal/shared
import ./internal/typestates_dsl
# Upstream `typestates` package's `typestate` / `destructorTransition`
# / `transitionError` DSL macros pulled in via
# `./internal/typestates_dsl` for the same name-shadow reason documented
# in `bqueue.nim` — a direct `import typestates` from this file would
# resolve to the local sibling `./typestates.nim` re-export module.
import debra/atomics
import ./backoff
import options
import std/typetraits

import ./exceptions

# nim-debra 0.8.0 surface — used for non-spsc cardinality combos only.
# The `(ccSingle, ccSingle)` branch is debra-free (committed-flag-free
# linked-segment protocol absorbed from the standalone `UnboundedSpsc`
# type). The import set is intentionally maintained for the other three
# cardinalities; Nim's dead-code elimination strips the unused symbols
# from the spsc-only instantiation.
from debra import
  DebraManager, ThreadHandle, PinnedScope, Destructor, initDebraManager, registerThread,
  bindClient, unbindClient, unpinned, pinScope, advanceEvery, reclaimNow,
  DebraRegistrationError, ThreadId, currentThreadId, `==`

from debra import retireOnCAS, retireOnPublish

export exceptions

# `stManual`, `stEager`, `ccSingle`, `ccMulti` travel with their enum
# type; any module that imports `queue` sees them. The `rkNone` / `rkEbr`
# enum members are no longer needed by `Queue` itself (the reclamation
# axis was eliminated), but the enum is re-exported for bench-adapter /
# migration-shim compatibility.
export
  DeallocationStrategy, ReclamationKind, PinScopeCardinality, Manual, Eager,
  DefaultDeallocationStrategy

# `NoSlice` lives in `internal/shared.nim`  Re-exported
# here so existing callers that consume it via `lockfreequeues/queue`
# continue to compile.
export NoSlice

const LockFreeQueuesAdvanceEvery* {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in the rkEbr Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

## ----------------------------------------------------------------------
## Middle-axis Lifecycle typestate.
##
## Tracks `QueueInit -> QueueDestroyed` on the unbounded Queue value.
## Parallel to `BQueue`'s Lifecycle typestate in `bqueue.nim` — same
## structural pattern, distinct context / state types because typestate
## attachments are unique per type (TA-004) and the bqueue/queue split
## demands independent lifecycles. Mirrors nim-debra
## `pinned_scope.nim:67-93` verbatim in shape.
##
## State-preserving discipline: every Queue
## state-preserving op (`push`, `pop`, `getProducer`, `getConsumer`,
## `retireOnCAS`, `retireOnPublish`, batch variants) declares NO
## `{.transition.}` pragma. They live in this module (queue.nim) so
## the same-module discipline is satisfied without `{.notATransition.}`.
##
## The terminal `QueueInit -> QueueDestroyed` transition is emitted by
## `=destroy` (further below in the file) via `destructorTransition`.
## ----------------------------------------------------------------------

type
  QueueLifecycleCtx*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = object of RootObj
    ## Phantom context type for the Queue Lifecycle typestate.

  QueueInit*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = distinct QueueLifecycleCtx[T, ccProd, ccCons, ST, S, MaxThreads]
    ## Initial Lifecycle state for an unbounded Queue.

  QueueDestroyed*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = distinct QueueLifecycleCtx[T, ccProd, ccCons, ST, S, MaxThreads]
    ## Terminal Lifecycle state for an unbounded Queue.

typestate QueueLifecycle[
    T,
    ccProd: static PinScopeCardinality,
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S: static int,
    MaxThreads: static int,
]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  strictTransitions = false
  states:
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]
    QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]
  initial:
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads]
  terminal:
    QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]
  transitions:
    QueueInit[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QueueDestroyed[T, ccProd, ccCons, ST, S, MaxThreads]

## ----------------------------------------------------------------------
## Middle-axis Claim-state typestate.
##
## Tracks `QueueClaimUnclaimed -> QueueClaimBothClaimed` on the
## QueueProducer / QueueConsumer view types. Parallel to the BQueue
## Claim-state in `bqueue.nim`. The state-type names carry a `QC`
## prefix (`QCUnclaimed` / `QCProducerClaimed` / ...) to disambiguate
## from BQueue's state types, which live in this build's same import
## graph via the `lockfreequeues` aggregator.
##
## Single object type per view, uniform attachment, ccMulti-only
## attach/detach methods. ccSingle callers hit a clean type-mismatch
## diagnostic with no `*Multi` / `*Single` leakage.
## ----------------------------------------------------------------------

type
  QueueClaimCtx*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = object of RootObj
    ## Phantom context for the QueueProducer / QueueConsumer Claim-state.

  QCUnclaimed*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = distinct QueueClaimCtx[T, ccProd, ccCons, ST, S, MaxThreads]

  QCProducerClaimed*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = distinct QueueClaimCtx[T, ccProd, ccCons, ST, S, MaxThreads]

  QCConsumerClaimed*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = distinct QueueClaimCtx[T, ccProd, ccCons, ST, S, MaxThreads]

  QCBothClaimed*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] = distinct QueueClaimCtx[T, ccProd, ccCons, ST, S, MaxThreads]

typestate QueueClaimState[
    T,
    ccProd: static PinScopeCardinality,
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S: static int,
    MaxThreads: static int,
]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  strictTransitions = false
  states:
    QCUnclaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCProducerClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCConsumerClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCBothClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
  initial:
    QCUnclaimed[T, ccProd, ccCons, ST, S, MaxThreads]
  terminal:
    QCBothClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
  transitions:
    QCUnclaimed[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QCProducerClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCUnclaimed[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QCConsumerClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCUnclaimed[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QCBothClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCProducerClaimed[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QCBothClaimed[T, ccProd, ccCons, ST, S, MaxThreads]
    QCConsumerClaimed[T, ccProd, ccCons, ST, S, MaxThreads] ->
      QCBothClaimed[T, ccProd, ccCons, ST, S, MaxThreads]

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
    ##     multi-producer coordination and for spsc-equiv (publish
    ##     via release).
    ##   - `head: int` — single-consumer non-atomic read position.
    ##     Present on `(ccProd × ccSingle)` shapes (mpsc-equiv and
    ##     the absorbed spsc-equiv). Only the single consumer ever
    ##     writes it.
    ##   - `committed: array[S, Atomic[bool]]` — multi-producer
    ##     publication flags. Present on `ccProd == ccMulti`.
    ##   - `prevConsumerIdx: Atomic[int]` — multi-consumer CAS slot.
    ##     Present on `ccCons == ccMulti`.
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    when ccCons == ccSingle:
      # mpsc-equiv + absorbed spsc-equiv: single-consumer
      # non-atomic read position.
      head* {.align: CacheLineBytes.}: int
    when ccProd == ccMulti:
      # mpsc-equiv + mpmc-equiv: multi-producer publication flags.
      committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
    when ccCons == ccMulti:
      # spmc-equiv + mpmc-equiv: multi-consumer CAS coordination.
      prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]

  Queue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] {.QueueLifecycle: QueueInit.} = object
    ## Unbounded lock-free queue, parameterized by producer/consumer
    ## cardinality, deallocation strategy `ST`, segment size `S`, and
    ## the debra registry capacity `MaxThreads`.
    ##
    ## Body layout splits on `(ccProd, ccCons) is (ccSingle, ccSingle)`:
    ##
    ##   - **spsc-absorbed** (ccSingle × ccSingle): no debra
    ##     integration. Linked-segment with committed-flag-free
    ##     SPSC protocol absorbed verbatim from the legacy
    ##     `UnboundedSpsc[S, T]` type. `MaxThreads` is a type-uniform
    ##     phantom — no thread-registry capacity is consumed.
    ##   - **non-spsc** (mpsc-/spmc-/mpmc-equiv): debra-
    ##     integrated. Owns `manager`, walks pin/retire chains in
    ##     `push`/`pop`. `MaxThreads` sizes the debra registry.
    when ccProd == ccSingle and ccCons == ccSingle:
      # Absorbed `UnboundedSpsc` body — no manager, no debra.
      headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      tailSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
      itemCount*: Atomic[int]
      segments*: Atomic[int]
    else:
      # Debra-integrated body. Manager CC is gated on `ccCons`:
      # nim-debra `cardinality.nim` REQUIRES `ccMulti` for consumer
      # pins on multi-consumer queues.
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
        # mpsc-equiv: the single consumer's debra handle is registered
        # at attach-time (`attachConsumer`) on the operating consumer
        # thread, NOT at construction (registerThread is thread-affine).
        # This flag records that attachConsumer has run; the mpsc
        # `pop` asserts it in debug builds.
        consumerAttached*: bool
        when defined(debug):
          # Debug-only thread-affinity stamp. Records the thread that ran
          # `attachConsumer()` (which registered the debra handle via
          # debra's `currentThreadId()`). The mpsc `pop()` asserts the
          # operating thread matches. `when defined(debug):` so release
          # builds carry NO field — zero layout change, zero cost.
          attachedTid*: ThreadId

## ----------------------------------------------------------------------
## Param-coherence guards — unbounded subset of legacy 
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
  ] {.QueueClaimState: QCUnclaimed.} = object
    ## Per-thread producer handle for an unbounded `Queue`. Retrieved
    ## via `Queue.getProducer()`. Defined for every (ccProd, ccCons)
    ## shape for type uniformity.
    ##
    ## For `ccProd == ccMulti` the producer carries a
    ## `ThreadHandle[MaxThreads, ...]` for the pin/unpin cycle in
    ## `push`. For `ccProd == ccSingle` the producer carries no
    ## handle (spsc/spmc-equiv have no pin requirement on push).
    ##
    ## Claim-state typestate : every view begins in
    ## `QCUnclaimed`. The optional `claimed` runtime flag (ccMulti
    ## only) tracks attach/detach state-preservingly (no static
    ## typestate transition). See `bqueue.nim` for the symmetric
    ## BQueueProducer pattern.
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, S, MaxThreads]
    when ccProd == ccMulti:
      # Producer.handle CC follows the manager.
      when ccCons == ccMulti:
        handle*: ThreadHandle[MaxThreads, debra.ccMulti]
      else:
        handle*: ThreadHandle[MaxThreads, debra.ccSingle]
      claimed*: bool
      when defined(debug):
        # Debug-only thread-affinity stamp. Records the thread that ran
        # `attach()` (which registered the debra handle via debra's
        # `currentThreadId()`). `push()` asserts the operating thread
        # matches. `when defined(debug):` so release builds carry NO
        # field — zero layout change, zero hot-path cost.
        attachedTid*: ThreadId

  QueueConsumer*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      S, MaxThreads: static int,
  ] {.QueueClaimState: QCUnclaimed.} = object
    ## Per-thread consumer handle for an unbounded `Queue`. Retrieved
    ## via `Queue.getConsumer()`. Defined for every (ccProd, ccCons)
    ## shape for type uniformity; only meaningful when
    ## `ccCons == ccMulti` (single-consumer cardinalities pop directly
    ## through `Queue.pop`).
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, S, MaxThreads]
    when ccCons == ccMulti:
      handle*: ThreadHandle[MaxThreads, debra.ccMulti]
      claimed*: bool
      when defined(debug):
        # Debug-only thread-affinity stamp. Records the thread that ran
        # `attach()` (which registered the debra handle via debra's
        # `currentThreadId()`). `pop()` asserts the operating thread
        # matches. `when defined(debug):` so release builds carry NO
        # field — zero layout change, zero hot-path cost.
        attachedTid*: ThreadId

## ----------------------------------------------------------------------
## Unbounded-queue body — absorbed spsc
## from `unbounded_spsc.nim` (B.2.5).
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
    # mpsc-equiv + absorbed spsc-equiv carry a `head: int` field.
    result.head = 0
  when ccProd == ccMulti:
    for i in 0 ..< S:
      result.committed[i].store(false, moRelaxed)
  when ccCons == ccMulti:
    result.prevConsumerIdx.store(-1, moRelaxed)

## ----------------------------------------------------------------------
## Per-queue retire wrappers — + γ guard.
##
## Defined only for non-spsc cardinalities (debra-integrated). Spsc-
## absorbed (`(ccSingle, ccSingle)`) has no debra integration and thus
## no retire-bearing site; UFCS lookup of `q.retireOn*` on a spsc
## queue fails with method-not-defined, which is the desired guard.
##
## `retireOnCAS` is callable under any consumer cardinality (DR-S3).
## `retireOnPublish` is additionally gated on `ccCons == ccSingle`
## (DR-S4 single-writer foot-gun). The spsc exclusion is also
## structurally enforced: spsc's `(ccCons == ccSingle)` could match
## `retireOnPublish`'s gate, but the receiver `var Queue[..., ccSingle,
## ccSingle, ...]` body lacks the segment-pointer atomics the wrapper
## consumes — the guard fires before any harm is done, and the
## documented design is that spsc is debra-free.
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
    expected: var U,
    desired: U,
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
##      (non-spsc) or just initializes the body (spsc). Works for
##      all 4 cardinality combos.
##   2. **typedesc + manager + handle** — manager-borrowed for
##      ccCons==ccSingle. The handle is consumed by mpsc-equiv only.
##   3. **typedesc + manager** — manager-borrowed for ccCons==ccMulti.
##
## A 4th overload `{.error.}`-gates the manager-borrowed signature on
## spsc-absorbed (`(ccSingle, ccSingle)`) since debra is not used
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
  ## variants (mpsc-equiv only; the spsc-absorbed `(ccSingle,
  ## ccSingle)` shape is debra-free and uses a separate `{.error.}`
  ## overload below).
  ##
  ## Caller owns the `DebraManager`. Sets `ownsManager = false`. The
  ## handle is consumed by mpsc-equiv (`ccProd == ccMulti`) and stored
  ## on the queue. ccProd-ccSingle spsc-equiv would be type-uniformly
  ## constructable here, but is excluded by the dedicated spsc
  ## `{.error.}` overload further below.
  validateQueueParams(Queue[T, ccProd, ccSingle, ST, S, MaxThreads])
  # ccProd == ccSingle here means spsc-absorbed, which is debra-free
  # and routes through the dedicated `{.error.}` overload below — so by
  # the time we reach this body, ccProd is effectively ccMulti
  # (mpsc-equiv).
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
    result.handle = handle
    # Escape hatch: the caller registered the consumer thread itself and
    # supplied the handle, so the queue is already attached on the
    # consumer side. Record it so the mpsc `pop` debug assert passes
    # without requiring a redundant `attachConsumer` call. (The auto-
    # create path leaves this false until `attachConsumer` runs.)
    result.consumerAttached = true
    when defined(debug):
      # Stamp the thread-affinity tid for the debug pop assert. The
      # escape-hatch contract is that the caller registered the consumer
      # handle on the thread that will pop; that thread also runs this
      # constructor, so `currentThreadId()` here is that pop thread.
      result.attachedTid = currentThreadId()
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
    _: typedesc[Queue[T, ccProd, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, debra.ccSingle],
): Queue[T, ccProd, ccSingle, ST, S, MaxThreads] =
  ## Handle-free manager-borrowed unbounded `newQueue` overload for
  ## ccCons == ccSingle (mpsc-equiv). The single consumer's debra
  ## handle is NOT registered here; the consumer thread registers itself
  ## via `attachConsumer()` before its first `pop`. The handle-carrying
  ## overload above remains the escape hatch for callers who register
  ## on the consumer thread and supply the handle directly.
  validateQueueParams(Queue[T, ccProd, ccSingle, ST, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
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
  ## variants (spmc-equiv + mpmc-equiv).
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
  ## ccCons == ccMulti (spmc-equiv and mpmc-equiv).
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

# Spsc-absorbed manager-borrowed `{.error.}` gate. The spsc-absorbed
# `(ccSingle, ccSingle)` body is debra-free; routing through a borrow
# overload would mis-shape the body. error string references
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
    "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
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
    "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
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
  ## Auto-create unbounded `newQueue` overload. For the spsc-absorbed
  ## `(ccSingle, ccSingle)` branch this skips manager allocation
  ## entirely. For the other three cardinality combos, allocates a
  ## private `DebraManager[MaxThreads, ...]` and sets `ownsManager =
  ## true`.
  ##
  ## **No thread is registered at construction.** `registerThread` is
  ## thread-affine (stamps the calling thread + installs a signal
  ## handler on the calling OS thread), so registering here would
  ## mis-route the handle when the queue is later operated on a
  ## different thread. Each operating thread registers itself at
  ## attach-time: producers/consumers via `getProducer().attach()` /
  ## `getConsumer().attach()`, and the mpsc-equiv single consumer via
  ## `attachConsumer()` before its first `pop`.
  validateQueueParams(Queue[T, ccProd, ccCons, ST, S, MaxThreads])
  when ccProd == ccSingle and ccCons == ccSingle:
    # Spsc-absorbed: no manager, no debra. Allocate initial segment
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
    # `allocAligned`'s zero-fill is not tracked by ARC/ORC, so a later
    # `mgr[] = initDebraManager[...]()` would run the `DebraManager`
    # `=destroy` on uninitialized storage. Mark the slot moved-from
    # first to match the NRVO discipline applied in
    # benchmarks/nim/adapters/lockfreequeues_unbounded_*_adapter.nim.
    wasMoved(mgr[])
    var ok = false
    try:
      when ccCons == ccMulti:
        mgr[] = initDebraManager[MaxThreads, debra.ccMulti]()
        result = newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads], mgr)
      else:
        mgr[] = initDebraManager[MaxThreads, debra.ccSingle]()
        # mpsc-equiv: no consumer handle registered here. The single
        # consumer calls `attachConsumer()` on its own thread.
        result = newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads], mgr)
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
  ## `ccProd == ccMulti` the view is created **unregistered**: the
  ## calling thread reserves a producer index but does NOT register
  ## against the queue's `DebraManager` here. Registration is
  ## thread-affine and happens at `attach()`-time, on the thread that
  ## will actually `push`. `attach()` therefore MUST be called on the
  ## thread that will subsequently `push()` through the returned view;
  ## registering on one thread and pushing from another mis-routes the
  ## debra handle. See `attach`.
  result.queue = addr(self)
  when ccProd == ccMulti:
    let idx = self.producerCount.fetchAdd(1, moAcquire)
    result.idx = idx
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
  ## `ccCons == ccMulti` the view is created **unregistered**: the
  ## calling thread reserves a consumer index but does NOT register
  ## against the queue's `DebraManager` here. Registration is
  ## thread-affine and happens at `attach()`-time, on the thread that
  ## will actually `pop`. `attach()` therefore MUST be called on the
  ## thread that will subsequently `pop()` through the returned view;
  ## registering on one thread and popping from another mis-routes the
  ## debra handle. See `attach`.
  result.queue = addr(self)
  when ccCons == ccMulti:
    let idx = self.consumerCount.fetchAdd(1, moAcquire)
    result.idx = idx
  else:
    result.idx = -1

template getProducerHere*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
): QueueProducer[T, ccProd, ccCons, ST, S, MaxThreads] =
  ## Sugar: `getProducer()` + `attach()` in one call.
  ##
  ## Use when the calling thread is also the operating thread (the
  ## thread that will subsequently `push()` through the returned view).
  ## This is the common SPSC case and the same-thread MP/MC case
  ## (e.g., bench harnesses where the spawning thread is also the
  ## producer).
  ##
  ## For the producer-to-worker handoff pattern (a parent thread
  ## obtains the view and hands it off to a worker thread that does
  ## the pushing), use `getProducer()` + `attach()` separately so the
  ## debra registration lands on the worker thread. See `getProducer`
  ## and `attach` for the thread-affinity contract.
  ##
  ## For `ccProd == ccSingle` (SPSC / SPMC producer side) `attach()`
  ## is a no-op (debra-free), so this template is purely syntactic
  ## sugar for those shapes.
  ##
  ## Raises `DebraRegistrationError` from the underlying `attach()`
  ## when `ccProd == ccMulti` and the manager's `MaxThreads` registry
  ## capacity is exhausted.
  var view = self.getProducer()
  when ccProd == ccMulti:
    view.attach()
  view

template getConsumerHere*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
): QueueConsumer[T, ccProd, ccCons, ST, S, MaxThreads] =
  ## Sugar: `getConsumer()` + `attach()` in one call.
  ##
  ## Use when the calling thread is also the operating thread (the
  ## thread that will subsequently `pop()` through the returned view).
  ## This is the common SPSC case and the same-thread MP/MC case.
  ##
  ## For the consumer-to-worker handoff pattern (a parent thread
  ## obtains the view and hands it off to a worker thread that does
  ## the popping), use `getConsumer()` + `attach()` separately so the
  ## debra registration lands on the worker thread. See `getConsumer`
  ## and `attach` for the thread-affinity contract.
  ##
  ## For `ccCons == ccSingle` (SPSC / MPSC consumer side) `attach()`
  ## is a no-op (debra-free), so this template is purely syntactic
  ## sugar for those shapes.
  ##
  ## Raises `DebraRegistrationError` from the underlying `attach()`
  ## when `ccCons == ccMulti` and the manager's `MaxThreads` registry
  ## capacity is exhausted.
  var view = self.getConsumer()
  when ccCons == ccMulti:
    view.attach()
  view

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
##   - spsc-absorbed (ccSingle × ccSingle): no pin, no committed-flag;
##     simple tail/`next` linked-segment advance. Lifted verbatim from
##     the legacy `unbounded_spsc.nim` push.
##   - spmc-equiv (ccSingle × ccMulti): no pin (single producer),
##     simple tail advance.
##   - mpsc/mpmc-equiv (ccMulti × _): pin via
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
    # Spsc-absorbed — no pin, no committed flag, no debra.
    # Lifted verbatim from `unbounded_spsc.nim:83-115`.
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
    # spmc-equiv — no pin (single producer).
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
    # ccProd == ccMulti — mpsc-equiv + mpmc-equiv share the push
    # body shape (the cardinality difference is on the consumer side).
    # Debug precondition: the producer view must have been claimed via
    # `attach()` on this thread (which registers the debra handle), so
    # the handle pinned below routes to the calling thread's slot.
    # Mirrors the mpsc-equiv `pop` assert form (bare `assert`,
    # compiled out under `-d:release` / `--assertions:off`).
    assert self.claimed,
      "producer view: call attach() on this thread before push()"
    when defined(debug):
      assert self.attachedTid == currentThreadId(),
        "producer view: attach() was called on a different thread than " &
        "this push(); the operating thread must be the thread that " &
        "registered the debra handle (thread-affinity contract)"
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
## carrier decision: pop lives on bare `Queue` for
## ccCons == ccSingle variants (spsc-absorbed + mpsc-equiv) and on
## `QueueConsumer` for ccCons == ccMulti variants (spmc-equiv,
## mpmc-equiv).
## ----------------------------------------------------------------------

# --- spsc-absorbed pop (ccSingle × ccSingle, direct on Queue, no pin) -----
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
): Option[T] =
  ## Spsc-absorbed pop — direct slot read + segment advance with
  ## `freeAligned(oldSeg)`. No pin (no retire-race; only one consumer
  ## ever runs, only one producer ever writes). Lifted verbatim from
  ## `unbounded_spsc.nim:122-166`.
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

# --- mpsc-equiv pop (ccMulti × ccSingle, direct on Queue, retireOnPublish) -
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]
): Option[T] =
  ## mpsc-equiv pop — §3.5.1 retire-bearing site.
  ##
  ## Debug precondition: the consumer thread must have registered its
  ## debra handle via `attachConsumer()` (or supplied it through the
  ## handle-carrying borrow constructor) before the first `pop`. The
  ## assert is compiled out under `-d:release` / `--assertions:off`, so
  ## it adds no hot-path cost in release builds.
  assert self.consumerAttached,
    "mpsc Queue.pop called before attachConsumer(): the consumer " &
    "thread must register its debra handle on its own thread first"
  when defined(debug):
    assert self.attachedTid == currentThreadId(),
      "mpsc Queue.pop: attachConsumer() was called on a different " &
      "thread than this pop(); the operating thread must be the thread " &
      "that registered the debra handle (thread-affinity contract)"
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

# --- spmc-equiv pop (ccSingle × ccMulti, via QueueConsumer, retireOnCAS) -
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var QueueConsumer[T, ccSingle, ccMulti, ST, S, MaxThreads]
): Option[T] =
  ## spmc-equiv pop — §3.5.3 retire-bearing site.
  ##
  ## Debug precondition: the consumer view must have been claimed via
  ## `attach()` on this thread (which registers the debra handle), so the
  ## handle pinned below routes to the calling thread's slot. Mirrors the
  ## mpsc-equiv `pop` assert form (bare `assert`, compiled out under
  ## `-d:release` / `--assertions:off`).
  assert self.claimed,
    "consumer view: call attach() on this thread before pop()"
  when defined(debug):
    assert self.attachedTid == currentThreadId(),
      "spmc consumer view: attach() was called on a different thread " &
      "than this pop(); the operating thread must be the thread that " &
      "registered the debra handle (thread-affinity contract)"
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

# --- mpmc-equiv pop (ccMulti × ccMulti, via QueueConsumer, retireOnCAS) -
proc pop*[T; ST: static DeallocationStrategy, S, MaxThreads: static int](
    self: var QueueConsumer[T, ccMulti, ccMulti, ST, S, MaxThreads]
): Option[T] =
  ## mpmc-equiv pop — §3.5.2 retire-bearing site.
  ##
  ## Debug precondition: the consumer view must have been claimed via
  ## `attach()` on this thread (which registers the debra handle), so the
  ## handle pinned below routes to the calling thread's slot. Mirrors the
  ## mpsc-equiv `pop` assert form (bare `assert`, compiled out under
  ## `-d:release` / `--assertions:off`).
  assert self.claimed,
    "consumer view: call attach() on this thread before pop()"
  when defined(debug):
    assert self.attachedTid == currentThreadId(),
      "mpmc consumer view: attach() was called on a different thread " &
      "than this pop(); the operating thread must be the thread that " &
      "registered the debra handle (thread-affinity contract)"
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
# compile-time `{.error.}` overload. References user-visible
# alias name `QueueConsumer`.
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

## ----------------------------------------------------------------------
## Claim-state attach / detach for QueueProducer / QueueConsumer.
##
## Signatures bind ccMulti only; ccSingle callers receive a clean
## type-mismatch diagnostic with no `*Multi` / `*Single` backing-type
## leakage. State-preserving — no `{.transition.}` pragma; same-module
## discipline satisfied since QueueClaimState is declared in this file.
## ----------------------------------------------------------------------

proc attach*[
    T;
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueProducer[T, ccMulti, ccCons, ST, S, MaxThreads]
) {.raises: [DebraRegistrationError].} =
  ## Claim a multi-producer QueueProducer view on the calling thread.
  ##
  ## Registers the calling thread against the queue's `DebraManager`
  ## (thread-affine) and stores the resulting `ThreadHandle` on the
  ## view, then marks it claimed. Guarded by `claimed` so a repeated
  ## attach on the same view does not burn a second registry slot.
  ## Runtime-only (no static typestate transition).
  ##
  ## **Thread-affinity contract:** MUST be called on the thread that
  ## will subsequently `push()` through this view. Registering on one
  ## thread and pushing from another mis-routes the debra handle (the
  ## handle carries the registering thread's slot index; debra applies
  ## it verbatim with no cross-thread check — see PART A / debra
  ## `guard.pin`).
  ##
  ## **Slot accounting:** each `attach()` consumes one `MaxThreads`
  ## registration slot for the lifetime of the owned `DebraManager`
  ## (debra 0.8.0 has no per-thread unregister). `detach()` does NOT
  ## free the slot. Size `MaxThreads` for the total number of DISTINCT
  ## threads that will ever operate this queue, not the peak concurrent
  ## count. Repeated `detach()` / re-`attach()` on the same thread burns
  ## a slot each time.
  ##
  ## Raises `DebraRegistrationError` when the manager's `MaxThreads`
  ## registry capacity is exhausted (the error is surfaced, never
  ## swallowed).
  if not self.claimed:
    self.handle = registerThread(self.queue.manager[])
    self.claimed = true
    when defined(debug):
      self.attachedTid = currentThreadId()

proc detach*[
    T;
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueProducer[T, ccMulti, ccCons, ST, S, MaxThreads]
) {.raises: [].} =
  ## Release a multi-producer QueueProducer view's claim.
  ##
  ## Only clears the claim flag; it does NOT unregister the debra handle
  ## (debra 0.8.0 has no per-thread unregister, so the `MaxThreads` slot
  ## stays consumed). `detach()` is idempotent; calling it on an
  ## already-detached view is a no-op.
  self.claimed = false

proc attach*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueConsumer[T, ccProd, ccMulti, ST, S, MaxThreads]
) {.raises: [DebraRegistrationError].} =
  ## Claim a multi-consumer QueueConsumer view on the calling thread.
  ##
  ## Registers the calling thread against the queue's `DebraManager`
  ## (thread-affine) and stores the resulting `ThreadHandle` on the
  ## view, then marks it claimed. Guarded by `claimed` so a repeated
  ## attach on the same view does not burn a second registry slot.
  ## Runtime-only (no static typestate transition).
  ##
  ## **Thread-affinity contract:** MUST be called on the thread that
  ## will subsequently `pop()` through this view. Registering on one
  ## thread and popping from another mis-routes the debra handle.
  ##
  ## **Slot accounting:** each `attach()` consumes one `MaxThreads`
  ## registration slot for the lifetime of the owned `DebraManager`
  ## (debra 0.8.0 has no per-thread unregister). `detach()` does NOT
  ## free the slot. Size `MaxThreads` for the total number of DISTINCT
  ## threads that will ever operate this queue, not the peak concurrent
  ## count. Repeated `detach()` / re-`attach()` on the same thread burns
  ## a slot each time.
  ##
  ## Raises `DebraRegistrationError` when the manager's `MaxThreads`
  ## registry capacity is exhausted.
  if not self.claimed:
    self.handle = registerThread(self.queue.manager[])
    self.claimed = true
    when defined(debug):
      self.attachedTid = currentThreadId()

proc detach*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueConsumer[T, ccProd, ccMulti, ST, S, MaxThreads]
) {.raises: [].} =
  ## Release a multi-consumer QueueConsumer view's claim.
  ##
  ## Only clears the claim flag; it does NOT unregister the debra handle
  ## (debra 0.8.0 has no per-thread unregister, so the `MaxThreads` slot
  ## stays consumed). `detach()` is idempotent; calling it on an
  ## already-detached view is a no-op.
  self.claimed = false

## ----------------------------------------------------------------------
## mpsc-equiv (ccMulti × ccSingle) consumer attach.
##
## The single consumer pops directly through `Queue.pop` (no view), so
## it has no `attach()`. Instead it registers its debra handle once, on
## its own thread, via `attachConsumer` before its first `pop`. This is
## the thread-affinity fix for the auto-create constructor, which no
## longer registers the consumer handle at construction time.
## ----------------------------------------------------------------------

proc attachConsumer*[
    T;
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]
) {.raises: [DebraRegistrationError].} =
  ## Register the calling thread as the mpsc-equiv single consumer.
  ##
  ## **Thread-affinity contract:** MUST be called on the thread that
  ## will subsequently `pop`, before the first `pop`. Registering on one
  ## thread and popping from another mis-routes the debra handle (the
  ## handle carries the registering thread's slot index; debra applies
  ## it verbatim with no cross-thread check). Registers against the
  ## queue's `DebraManager` (thread-affine) and stores the resulting
  ## `ThreadHandle` on the queue, then records `consumerAttached = true`
  ## (asserted at the top of `pop` in debug builds). Idempotent: a
  ## repeat call is guarded so it does not burn a second registry slot.
  ##
  ## **Slot accounting:** this registration consumes one `MaxThreads`
  ## registration slot for the lifetime of the owned `DebraManager`
  ## (debra 0.8.0 has no per-thread unregister). There is no
  ## consumer-side `detach()` to release it. Size `MaxThreads` for the
  ## total number of DISTINCT threads that will ever operate this queue,
  ## not the peak concurrent count.
  ##
  ## Raises `DebraRegistrationError` when `MaxThreads` is exhausted.
  ## Callers using the handle-carrying borrow `newQueue` overload
  ## (escape hatch) register the handle themselves and must NOT call
  ## `attachConsumer`.
  if not self.consumerAttached:
    self.handle = registerThread(self.manager[])
    self.consumerAttached = true
    when defined(debug):
      self.attachedTid = currentThreadId()

## ----------------------------------------------------------------------
## Destructors driving Lifecycle / Claim-state terminal transitions
##. Mirror BQueue's pattern.
## ----------------------------------------------------------------------

proc `=copy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    dst: var Queue[T, ccProd, ccCons, ST, S, MaxThreads],
    src: Queue[T, ccProd, ccCons, ST, S, MaxThreads],
) {.error:
    "Queue is non-copyable: it owns a `ptr Segment` chain and (for " &
    "non-spsc cardinalities) a `ptr DebraManager`. Copying would " &
    "alias these owned pointers and double-free / use-after-free at " &
    "`=destroy`. Move the Queue (it has `=destroy` move semantics) or " &
    "share it by `ptr`/`var` parameter instead.".}
  ## Compile-time copy ban. A Queue owns heap state (segment chain +
  ## optionally the debra manager, recorded by `ownsManager`) that is
  ## reclaimed exactly once in `=destroy`. A field-wise copy would
  ## duplicate the owning `ptr`s and reclaim them twice. Move semantics
  ## (the implicit `=sink` synthesized alongside `=destroy`) remain
  ## available; only copies are rejected.

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]) {.
    destructorTransition: QueueInit -> QueueDestroyed,
    transitionError:
      "Queue used after =destroy (lifecycle: QueueInit -> QueueDestroyed).",
    raises: [],
.} =
  ## Destructor. Walks `headSegment` → `next` → ... freeing each
  ## segment. For non-spsc cardinalities, additionally unbinds the
  ## client refcount on the manager and (when `ownsManager`) runs the
  ## manager's destructor.
  ##
  ## Also drives the Lifecycle terminal transition
  ## (`QueueInit -> QueueDestroyed`) via `destructorTransition`.
  ##
  ## **Precondition:** all worker threads that attached to this queue
  ## must be joined before `=destroy` runs. debra 0.8.0 has no
  ## per-thread unregister; thread handles live until the manager is
  ## destroyed here. Destroying the queue while an attached worker is
  ## still pinning/popping is undefined. For shared-manager queues
  ## (`ownsManager == false`) the destructor only unbinds the client
  ## refcount; the manager is left intact for its owner to free.
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

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var QueueProducer[T, ccProd, ccCons, ST, S, MaxThreads]) {.
    destructorTransition: QCUnclaimed -> QCBothClaimed,
    transitionError:
      "QueueProducer used after =destroy (claim-state: QCUnclaimed -> QCBothClaimed).",
    raises: [],
.} =
  ## QueueProducer destructor — drives the Claim-state terminal
  ## transition. View carries no owned heap state; the underlying
  ## ThreadHandle is borrow-only (released via the parent Queue).
  discard

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var QueueConsumer[T, ccProd, ccCons, ST, S, MaxThreads]) {.
    destructorTransition: QCUnclaimed -> QCBothClaimed,
    transitionError:
      "QueueConsumer used after =destroy (claim-state: QCUnclaimed -> QCBothClaimed).",
    raises: [],
.} =
  ## QueueConsumer destructor — drives the Claim-state terminal
  ## transition.
  discard

## ----------------------------------------------------------------------
## Family-named unbounded smart constructors — kept as thin wrappers.
##
## Every signature returns `Queue[...]`, never a backing type.
## ----------------------------------------------------------------------

proc newUnboundedSpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded spsc-absorbed (`ccSingle × ccSingle`) auto-create
  ## smart-constructor. Skips manager allocation (spsc-absorbed has
  ## no debra integration). Added in B.2.5 alongside the absorption.
  newQueue(Queue[T, ccSingle, ccSingle, ST, S, MaxThreads])

proc newUnboundedMpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccSingle],
    consumerHandle: ThreadHandle[MaxThreads, debra.ccSingle],
): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpsc-equivalent (`ccMulti × ccSingle`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads], manager, consumerHandle)

proc newUnboundedMpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccSingle]
): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpsc-equivalent (`ccMulti × ccSingle`) borrow
  ## smart-constructor — manager-only form. The consumer's debra handle
  ## is NOT registered here; the consumer thread registers itself via
  ## `attachConsumer()` before its first `pop`. Use the
  ## `(manager, consumerHandle)` overload (escape hatch) to register the
  ## consumer thread yourself and supply the handle at construction.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads], manager)

proc newUnboundedMpscQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpsc-equivalent (`ccMulti × ccSingle`) auto-create
  ## smart-constructor. No thread is registered at construction: the
  ## consumer thread calls `attachConsumer()` and producer threads call
  ## `getProducer().attach()` on their own threads.
  newQueue(Queue[T, ccMulti, ccSingle, ST, S, MaxThreads])

proc newUnboundedSpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccMulti]
): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded spmc-equivalent (`ccSingle × ccMulti`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccSingle, ccMulti, ST, S, MaxThreads], manager)

proc newUnboundedSpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded spmc-equivalent (`ccSingle × ccMulti`) auto-create
  ## smart-constructor.
  newQueue(Queue[T, ccSingle, ccMulti, ST, S, MaxThreads])

proc newUnboundedMpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    manager: ptr DebraManager[MaxThreads, debra.ccMulti]
): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpmc-equivalent (`ccMulti × ccMulti`) borrow
  ## smart-constructor.
  newQueue(Queue[T, ccMulti, ccMulti, ST, S, MaxThreads], manager)

proc newUnboundedMpmcQueue*[
    T;
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpmc-equivalent (`ccMulti × ccMulti`) auto-create
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
