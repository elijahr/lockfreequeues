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

import ./endpoint_types
import ./role_tags
from debra import pinScope, unpinned, advanceEvery, reclaimNow

when defined(debug):
  import std/typedthreads

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

# ----------------------------------------------------------------------
# Strict-LCRQ cell alias + close sentinel (Phase B / §2.1, §4).
#
# `LCRQCell[T]` is a *transparent* alias for `Atomic[Pair[uint64, T]]`:
# a single 128-bit DWCAS-able cell whose first half is the seq counter
# (`Pair.first`, encoding empty=0 / filled=1 / closed=high-bit) and
# whose second half is the payload of type `T`. This replaces the
# v4.x `committed: Atomic[bool]` + `data[i]: T` overlay on the
# unbounded MPMC arm, unlocking the §4 close-on-empty progress
# guarantee via DWCAS arbitration.
#
# `CLOSED_BIT` is the close sentinel: a cell with `seq == CLOSED_BIT`
# is permanently closed — no producer can publish into it and no
# consumer can claim it. The high bit is reserved for this purpose;
# the remaining 63 bits encode the empty/filled epoch counter.
#
# These are type-level / constant introductions only — no production
# call site references them yet. T2 lands the three cell primitives
# (`tryPublish` / `tryClaim` / `tryCloseOnEmpty`) that consume them;
# later tasks migrate `Segment` and `newSegment` to use a
# `cells: array[S, LCRQCell[T]]` field on the MPMC arm.
#
# The width invariant (`sizeof(LCRQCell[T]) == 16` for any `T` with
# `sizeof(T) == 8`) and the `CLOSED_BIT` bit position are guarded by
# `tests/t_lcrq_cell_alias.nim`.
# ----------------------------------------------------------------------
const CLOSED_BIT* = 1'u64 shl 63
  ## Strict-LCRQ §4 close sentinel. A cell with `seq == CLOSED_BIT`
  ## is permanently closed: no producer can publish into it, no
  ## consumer can claim it. See design §2.2.

type LCRQCell*[T] = Atomic[Pair[uint64, T]]
  ## Strict-LCRQ cell: 128-bit DWCAS-able pair of seq counter
  ## (`Pair.first`) and payload (`Pair.second`). Transparent alias
  ## for `Atomic[Pair[uint64, T]]` — assigning a `LCRQCell[T]` to /
  ## from the spelled-out type requires no conversion. See design
  ## §2.1 (cell shape) and §4 (close-on-empty progress argument).

# ----------------------------------------------------------------------
# Strict-LCRQ cell primitives (Phase B / §2.3, §2.3.1, §8).
#
# Three pure DWCAS primitives on `LCRQCell[T]`. Each is a single
# `compareExchangeStrong` wrapped in `dwcasOrderRelaxedCAS` to silence
# the nim-debra `validCasFailureOrder` warning that fires for the
# `success=moRelease, failure=moRelaxed` pair on DWCAS sites where the
# seq_cst-upgrade would be a perf footgun (design §8 closing
# paragraphs).
#
# Memory ordering per design §8 / §8.1 (C11-strict, no upgrades):
#   tryPublish:        success = moRelease,        failure = moRelaxed
#   tryClaim:          success = moAcquireRelease, failure = moRelaxed
#   tryCloseOnEmpty:   success = moRelease,        failure = moRelaxed
#
# `tryClaim`'s seq-load uses `moAcquire` to synchronise-with the
# producer's `moRelease` publish — the CAS-failure ordering only
# governs the failure-path re-read, which we discard.
#
# CRITICAL contract correction over the Phase A.5 spike (design §2.3.1
# / CRITICAL-1): `tryClaim` NEVER inspects `observed.second`. The CAS
# on the seq encoding is the SOLE authority on cell state. The spike's
# `if observed.second == default(T): return none(T)` short-circuit
# silently dropped legitimate `q.push(0)` / `q.push(nil)` publishes;
# the production primitive does not.
#
# `expectedSeq` is invariantly `0` at v5.0.0 call sites (linked-segment
# specialization, R degenerate per design §2.5 / §2.5.3); the parameter
# is retained on the primitive signatures with a documented roadmap
# trigger for a future ring-segment variant.
# ----------------------------------------------------------------------

proc tryPublish*[T](cell: var LCRQCell[T], expectedSeq: uint64, value: T): bool =
  ## §2.3 / §4. Producer publish via DWCAS into an empty cell.
  ## Returns true on success (cell now `(expectedSeq+1, value)`).
  ## Returns false if the cell is already filled, closed, or at a
  ## different epoch.
  ##
  ## Precondition for `T is ptr|ref`: `value` MUST NOT be nil. The
  ## std/options transport used by `tryClaim` (`some(val: ptr X)`)
  ## asserts `not val.isNil` at runtime; forbidding nil here surfaces
  ## the contract violation at the producer rather than as a delayed
  ## AssertionDefect inside an unrelated consumer's `tryClaim` call.
  ## See design §2.5.2 / §11. `doAssert` (not `assert`) so the guard
  ## survives `-d:danger` builds.
  when T is ptr or T is ref:
    doAssert value != nil,
      "Queue: cannot push nil for ptr/ref T (Option transport restriction)"
  let expected = Pair[uint64, T](first: expectedSeq, second: default(T))
  let desired = Pair[uint64, T](first: expectedSeq + 1, second: value)
  var prev = expected
  # On CAS failure, debra writes the observed pair into `prev`; we don't
  # re-read it — escalation re-loads via fresh cell.load at the call site
  # (queue.nim push/pop). Required for the degenerate-R encoding (design §2.5.2).
  dwcasOrderRelaxedCAS:
    result = compareExchangeStrong(cell, prev, desired, moRelease, moRelaxed)

proc tryClaim*[T](cell: var LCRQCell[T], expectedSeq: uint64): Option[T] =
  ## §2.3 / §2.3.1 (CRITICAL-1). Consumer claim via DWCAS.
  ##
  ## CONTRACT: NEVER inspect `observed.second`. The CAS on the seq
  ## encoding is the sole authority on cell state. A filled cell with
  ## payload `default(T)` (e.g. `q.push(0)`, `q.push(nil)`) is a
  ## legitimate publish and MUST be returned via `some(observed.second)`.
  let observed = load(cell, moAcquire)
  if observed.first != expectedSeq + 1:
    return none(T)
  let desired = Pair[uint64, T](first: observed.first, second: default(T))
  var prev = observed
  dwcasOrderRelaxedCAS:
    if compareExchangeStrong(cell, prev, desired, moAcquireRelease, moRelaxed):
      return some(observed.second)
  return none(T)

proc tryCloseOnEmpty*[T](cell: var LCRQCell[T], expectedSeq: uint64): bool =
  ## §2.3 / §4. Consumer close-on-empty via DWCAS. Atomically sets
  ## `CLOSED_BIT` on an empty cell so no producer can later publish
  ## into it. Returns false if the cell is already filled or closed.
  let expected = Pair[uint64, T](first: expectedSeq, second: default(T))
  let desired = Pair[uint64, T](first: expectedSeq or CLOSED_BIT, second: default(T))
  var prev = expected
  # On CAS failure, debra writes the observed pair into `prev`; we don't
  # re-read it — escalation re-loads via fresh cell.load at the call site
  # (queue.nim push/pop). Required for the degenerate-R encoding (design §2.5.2).
  dwcasOrderRelaxedCAS:
    result = compareExchangeStrong(cell, prev, desired, moRelease, moRelaxed)

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
  ] = object of RootObj ## Phantom context type for the Queue Lifecycle typestate.

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

type
  Segment*[T; ccProd, ccCons: static PinScopeCardinality, S: static int] = object
    ## Unbounded-queue segment. One linked-segment payload, parameterized
    ## by `(ccProd, ccCons)` so each cardinality variant's field set
    ## matches its per-family analogue.
    ##
    ## Field set:
    ##   - `data: array[S, T]` — slot storage (non-MPMC variants).
    ##   - `cells: array[S, LCRQCell[T]]` — strict-LCRQ cells (MPMC only,
    ##     Phase B migration target). Replaces `committed + data` on the
    ##     `ccMulti × ccMulti` arm.
    ##   - `next: Atomic[ptr Segment[...]]` — linked-list pointer.
    ##   - `tail: Atomic[int]` — producer write index. Atomic for
    ##     multi-producer coordination and for spsc-equiv (publish
    ##     via release).
    ##   - `head: int` — single-consumer non-atomic read position.
    ##     Present on `(ccProd × ccSingle)` shapes (mpsc-equiv and
    ##     the absorbed spsc-equiv). Only the single consumer ever
    ##     writes it.
    ##   - `committed: array[S, Atomic[bool]]` — multi-producer
    ##     publication flags. Present on `ccProd == ccMulti and
    ##     ccCons == ccSingle` (MPSC only — MPMC migrated to `cells`).
    ##   - `prevConsumerIdx: Atomic[int]` — multi-consumer CAS slot.
    ##     Present on `ccCons == ccMulti`.
    when ccProd == ccMulti and ccCons == ccMulti:
      # MPMC: strict-LCRQ cells (Phase B). Replaces committed+data.
      cells* {.align: CacheLineBytes.}: array[S, LCRQCell[T]]
    elif ccProd == ccMulti:
      # MPSC (ccMulti × ccSingle): legacy committed+data overlay
      # preserved verbatim (NOT migrating in Phase B; symmetric with
      # BQueue staying unchanged).
      data*: array[S, T]
    else:
      # SPSC + SPMC: data only.
      data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    when ccCons == ccSingle:
      # mpsc-equiv + absorbed spsc-equiv: single-consumer
      # non-atomic read position.
      head* {.align: CacheLineBytes.}: int
    when ccProd == ccMulti and ccCons == ccSingle:
      # MPSC-only multi-producer publication flags. MPMC migrated to
      # `cells` (above) where the seq counter subsumes commit-bit.
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
  when ccProd == ccMulti and ccCons == ccMulti:
    # MPMC strict-LCRQ: each cell starts in the §2.5.1 empty state
    # `(seq=0, default(T))`. While `allocAligned` already returns
    # zero-initialized memory (so this loop is observationally a
    # no-op for the cell-shape we ship), the explicit relaxed store
    # is the correct-by-construction publication of the design's
    # empty-cell encoding and pins the invariant against any future
    # change to the allocator or to `default(T)` for non-trivial T.
    # Synchronization: relaxed is sufficient — the segment is not
    # visible to other threads until the producer/consumer link it
    # into the queue chain via a release-store.
    let zero = Pair[uint64, T](first: 0'u64, second: default(T))
    for i in 0 ..< S:
      store(result.cells[i], zero, moRelaxed)
  elif ccProd == ccMulti:
    # MPSC: legacy committed flags init (unchanged).
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
    when ccProd == ccMulti and ccCons == ccMulti:
      # STRICT-LCRQ-PARTIAL: MPMC payload lives inside `cells[i]` as
      # `Pair[uint64, T].value`. T4-T8 will reset embedded T's via
      # the cell's value field. For T3, the reset is intentionally
      # elided — MPMC suite is expected red across T3..T7.
      discard
    elif ccProd == ccMulti:
      # MPSC: legacy data array.
      for i in 0 ..< S:
        reset(seg.data[i])
    else:
      # SPSC + SPMC.
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
): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.
    error:
      "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
      "Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) " &
      "overload instead."
.} =
  discard

proc newQueue*[
    T;
    ST: static DeallocationStrategy,
    CC: static debra.PinScopeCardinality,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads, CC],
): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads] {.
    error:
      "Spsc-absorbed Queue (ccSingle × ccSingle) is debra-free. " &
      "Use the typedesc-only newQueue(Queue[..., ccSingle, ccSingle, ST, S, MaxThreads]) " &
      "overload instead."
.} =
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
      let value = move(seg.data[head])
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

# --- mpsc-equiv pop: REMOVED in v5.0.0 ----------------------------------
# The pre-v5.0.0 direct-on-Queue MPSC pop required `attachConsumer()`
# ceremony + carried `self.handle` / `self.consumerAttached` fields on
# Queue that were tied to the deleted QueueConsumer claim-state model.
# v5.0.0 routes MPSC pop through `Bound[T, Tag, Queue[..., ccSingle, ...]]`
# (see endpoint.nim's `getConsumer` factory + bqueue/queue's pop on
# Bound). Users go through `q.bindConsumer()` (or
# `q.getConsumer().bindToThread()`) to get a Bound endpoint, then call
# pop on it.

# --- batch pop (ccCons == ccSingle, direct on Queue) ----------------------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads], count: int): Option[seq[T]] =
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
# alias name `QueueConsumer`.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, S, MaxThreads]
): Option[T] {.
    error:
      "Direct pop on a multi-consumer Queue is not allowed. " &
      "Use q.getConsumerHere().pop() (same-thread sugar) or q.bindConsumer().pop() (one-shot SC consumer) to obtain a per-thread " &
      "Bound[T, Tag, Queue[...]] and pop through it."
.} =
  discard

# --- ccMulti-consumer compile-time gate on bare Queue batch pop ----------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, S, MaxThreads], count: int
): Option[seq[T]] {.
    error:
      "Direct batch pop on a multi-consumer Queue is not allowed. " &
      "Use q.getConsumerHere().pop(count) (same-thread sugar) or q.bindConsumer().pop(count) (one-shot SC consumer) to obtain a per-thread " &
      "Bound[T, Tag, Queue[...]] and batch-pop through it."
.} =
  discard

## ----------------------------------------------------------------------
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
) {.
  error:
    "Queue is non-copyable: it owns a `ptr Segment` chain and (for " &
    "non-spsc cardinalities) a `ptr DebraManager`. Copying would " &
    "alias these owned pointers and double-free / use-after-free at " &
    "`=destroy`. Move the Queue (it has `=destroy` move semantics) or " &
    "share it by `ptr`/`var` parameter instead."
.}
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
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
) {.
    destructorTransition: QueueInit -> QueueDestroyed,
    transitionError:
      "Queue used after =destroy (lifecycle: QueueInit -> QueueDestroyed).",
    raises: []
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
      when ccProd == ccMulti and ccCons == ccMulti:
        # STRICT-LCRQ-PARTIAL: MPMC payload lives in `cells[i].value`.
        # T4-T8 will reset embedded T's via the cell's value field.
        discard
      elif ccProd == ccMulti:
        # MPSC: legacy data array.
        for i in 0 ..< S:
          reset(seg.data[i])
      else:
        # SPSC + SPMC.
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
    manager: ptr DebraManager[MaxThreads, debra.ccSingle]
): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads] {.inline.} =
  ## Unbounded mpsc-equivalent (`ccMulti × ccSingle`) borrow
  ## smart-constructor — manager-only form. The consumer thread calls
  ## `q.bindConsumer()` on its own thread to register and obtain its
  ## `Bound` endpoint.
  ##
  ## The pre-v5.0.0 `(manager, consumerHandle)` borrow-with-handle
  ## overload was removed: in v5.0.0 the consumer's debra handle is
  ## owned by `Bound` (opaque storage), so pre-registering and passing
  ## a handle at construction is no longer the right ceremony.
  ## `bindConsumer` wraps registration + binding in one call.
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
## Push / pop on Bound endpoints — Track C v5.0.0 re-typing.
##
## Re-types the pre-v5.0.0 QueueProducer/QueueConsumer push/pop bodies
## onto `Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]]`
## receivers. The Bound endpoint carries opaque handle storage
## (`handleManager: pointer` + `handleIdx: int`); for the ccProd==ccMulti
## paths that need `pinScope(unpinned(handle))` the typed
## `ThreadHandle[MaxThreads, CC]` is reconstructed via cast at the call
## site (`when compiles(self.queue.manager)` gate + manager-pointer
## introspection — mirror of the onClose pattern in endpoint.nim).
##
## SPSC-absorbed and SPMC-equiv push paths are debra-free; they ignore
## the handle storage entirely.
## ----------------------------------------------------------------------

proc push*[
    T;
    Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag,
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]], item: sink T
) {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Push a single item onto the unbounded queue (cardinality-dispatched).
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item is ref; recompile with -d:allowNonLockFreeQueueItems.".}
  when defined(debug):
    assert self.attachedTid == getThreadId(),
      "push from wrong thread (must match bindToThread thread)"

  when ccProd == ccSingle and ccCons == ccSingle:
    # SPSC-absorbed — no pin, no committed flag, no debra.
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
    # spmc-equiv — single producer, no pin.
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
    # ccProd == ccMulti — mpsc/mpmc-equiv: pin claim required.
    type MgrT = typeof(self.queue.manager[])
    let mgr = cast[ptr MgrT](self.handleManager)
    type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
    let h = Handle(idx: self.handleIdx, manager: mgr)
    block:
      var scope {.used.} = pinScope(unpinned(h))
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
          when ccCons == ccMulti:
            # Strict-LCRQ MPMC publish via DWCAS into `cells[tail]`.
            # `expectedSeq = 0` is the invariant at v5.0.0 call sites
            # (linked-segment specialization, R degenerate per design
            # §2.5 / §2.5.3). On CAS failure the cell was unexpectedly
            # filled or closed — escalate via outer-loop retry; the
            # close-on-empty arbitration that motivates this escalation
            # lands with T9.
            if not tryPublish[T](seg.cells[tail], 0'u64, item):
              # STRICT-LCRQ-PARTIAL: T9 wires close-CAS-on-empty here — on
              # closed cell, must escalate to seg.next (not just bump tail).
              # Currently behaves correctly for non-closed failure (tail-CAS
              # rolls).
              continue
          else:
            # MPSC: legacy committed+data publish (unchanged).
            seg.data[tail] = item
            seg.committed[tail].store(true, moRelease)
          discard self.queue.itemCount.fetchAdd(1, moRelaxed)
          break

proc push*[
    T;
    Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag,
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]],
    items: openArray[T],
) {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Batch push (thin loop).
  for item in items:
    self.push(item)

# --- SPSC / MPSC pop on Bound (ccCons == ccSingle: no pin) ----------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccSingle, ST, S, MaxThreads]]
): Option[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Pop for `ccCons == ccSingle` (SPSC + MPSC). Single consumer thread,
  ## no pin required. Body lifted from the pre-v5.0.0 direct-on-Queue
  ## pop overloads (`queue.nim:1021` and `:1061`) with cardinality
  ## dispatch consolidated via the existing `when` arms.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item is ref; recompile with -d:allowNonLockFreeQueueItems.".}
  when defined(debug):
    assert self.attachedTid == getThreadId(), "pop from wrong thread"

  var seg = self.queue.headSegment.load(moAcquire)
  when ccProd == ccSingle:
    # SPSC-absorbed: head advances on the consumer side; no committed flag.
    let head = seg.head
    let tail = seg.tail.load(moAcquire)
    if head >= tail:
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        return none(T)
      self.queue.headSegment.store(nextSeg, moRelease)
      discard self.queue.segments.fetchSub(1, moRelaxed)
      return self.pop()
    let v = move(seg.data[head])
    seg.head = head + 1
    discard self.queue.itemCount.fetchSub(1, moRelaxed)
    return some(v)
  else:
    # MPSC: ccMulti producer × ccSingle consumer. The single consumer
    # owns the head walk but still pins the epoch via debra so
    # `retireOnPublish` knows a reader holds a segment. Single-consumer
    # cardinality avoids consumer-vs-consumer CAS coordination; it does
    # NOT avoid the epoch pin.
    type MgrT = typeof(self.queue.manager[])
    let mgr = cast[ptr MgrT](self.handleManager)
    type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
    let h = Handle(idx: self.handleIdx, manager: mgr)
    block:
      var scope = pinScope(unpinned(h))
      while true:
        let tail = seg.tail.load(moAcquire)
        if seg.head < tail:
          if seg.committed[seg.head].load(moAcquire):
            result = some(move(seg.data[seg.head]))
            inc seg.head
            discard self.queue.itemCount.fetchSub(1, moRelaxed)
          break
        let nextSeg = seg.next.load(moAcquire)
        if nextSeg == nil:
          break
        self.queue[].retireOnPublish(
          scope,
          self.queue.headSegment,
          nextSeg,
          segmentDestructor[T, ccMulti, ccSingle, S],
        )
        when ST != stManual:
          discard self.queue.segments.fetchSub(1, moRelaxed)
        seg = nextSeg
    when ST == stEager:
      if h.advanceEvery(LockFreeQueuesAdvanceEvery):
        discard reclaimNow(h)

# --- Batch pop on Bound for ccCons == ccSingle (SPSC + MPSC) -------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccSingle, ST, S, MaxThreads]], count: int
): Option[seq[T]] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## Batch pop for ccCons==ccSingle. Thin loop over single-item pop.
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

# --- SPMC pop on Bound (ccSingle producer × ccMulti consumer) ------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]]
): Option[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## SPMC pop — retire-bearing site. Pin claim via reconstructed
  ## ThreadHandle from opaque Bound storage.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item is ref; recompile with -d:allowNonLockFreeQueueItems.".}
  when defined(debug):
    assert self.attachedTid == getThreadId(), "pop from wrong thread"

  type MgrT = typeof(self.queue.manager[])
  let mgr = cast[ptr MgrT](self.handleManager)
  type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
  let h = Handle(idx: self.handleIdx, manager: mgr)

  block:
    var scope = pinScope(unpinned(h))
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
        result = some(move(seg.data[mySlot]))
        discard self.queue.itemCount.fetchSub(1, moRelaxed)
        break

  when ST == stEager:
    if h.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(h)

# --- MPMC pop on Bound (ccMulti producer × ccMulti consumer) --------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]]
): Option[T] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
  ## MPMC pop — retire-bearing site.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.error: "Queue item is ref; recompile with -d:allowNonLockFreeQueueItems.".}
  when defined(debug):
    assert self.attachedTid == getThreadId(), "pop from wrong thread"

  type MgrT = typeof(self.queue.manager[])
  let mgr = cast[ptr MgrT](self.handleManager)
  type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
  let h = Handle(idx: self.handleIdx, manager: mgr)

  block:
    var scope = pinScope(unpinned(h))
    var seg = self.queue.headSegment.load(moAcquire)
    var spins = InitialSpin
    while true:
      let tail = seg.tail.load(moAcquire)
      var prevIdx = seg.prevConsumerIdx.load(moAcquire)
      let mySlot = prevIdx + 1
      if mySlot >= tail:
        if mySlot < S and seg.tail.load(moAcquire) > mySlot:
          # STRICT-LCRQ-PARTIAL: was the published-bit check
          # `if not seg.committed[mySlot].load(moAcquire): break;
          # backoff; continue`. T4-T8 will replace with `tryClaim(
          # seg.cells[mySlot], expectedSeq)`. For T3 the slot is
          # never published (push stubs `wasMoved(item)`), so we
          # break out as if uncommitted — MPMC suite expected red.
          break
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
      # STRICT-LCRQ-PARTIAL: was the published-bit gate + CAS-claim path:
      #   if not seg.committed[mySlot].load(moAcquire): break
      #   if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, ...):
      #     result = some(move(seg.data[mySlot]))
      #     discard self.queue.itemCount.fetchSub(1, moRelaxed)
      #     break
      # T4-T8 will replace with `tryClaim(seg.cells[mySlot], expectedSeq)`
      # which subsumes both the publish-bit check and the value move.
      # For T3 the slot is never published, so we break out empty —
      # MPMC suite expected red.
      discard prevIdx
      break

  when ST == stEager:
    if h.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(h)

# --- Batch pop on Bound for ccCons == ccMulti ----------------------------
proc pop*[
    T;
    Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag,
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: Bound[T, Tag, Queue[T, ccProd, ccMulti, ST, S, MaxThreads]], count: int
): Option[seq[T]] {.tags: [Tag, TypestateOp, RootEffect], raises: [], notATransition.} =
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

## Same-thread shortcut helpers (`getProducerHere` / `getConsumerHere`)
## and `bindConsumer` live in `endpoint.nim` next to `getProducer` /
## `getConsumer` so the templates bind against the endpoint module's
## factories rather than any locally-shadowing `getProducer` /
## `getConsumer` proc at the expansion site.

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
    ## combos that carry it (`ccProd == ccMulti and ccCons == ccSingle`,
    ## i.e. MPSC only). MPMC migrated to `cells` in Phase B and will
    ## expose `segmentCellsOffsetForTest` in T10. Calling this with an
    ## MPMC cardinality fails at the `offsetOf` site (field absent).
    offsetOf(Segment[T, ccProd, ccCons, S], committed)

  proc segmentPrevConsumerIdxOffsetForTest*[
      T; ccProd, ccCons: static PinScopeCardinality, S: static int
  ](_: typedesc[Segment[T, ccProd, ccCons, S]]): int =
    ## Test-only accessor: returns offset of `prevConsumerIdx` for
    ## cardinality combos that carry it (`ccCons == ccMulti`).
    offsetOf(Segment[T, ccProd, ccCons, S], prevConsumerIdx)
