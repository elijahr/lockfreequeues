## Unified `Queue` generic — v5.0.0 type shell.
##
## This file declares the type shell only; method bodies follow in
## subsequent tracks:
##   - Track B (Manager B) fills the `when RK == rkNone:` push/pop ladder.
##   - Track E (Manager E) fills the `when RK == rkEbr:` push/pop ladder
##     and the γ retire wrappers (retireOnCAS / retireOnPublish).
##
## **rkEbr field-decl block:** the `when RK == rkEbr:` branch declares
## the 4-cardinality-variant unbounded-body fields per Doc C §3.0
## (`manager`, `headSegment`, `tailSegment`, `itemCount`, `segments`,
## `ownsManager`, plus `producerCount`/`consumerCount`/`handle`/
## `consumerHeads` gated by cardinality). The block takes a dependency
## on nim-debra 0.8.0 (`DebraManager`, `ThreadHandle`) resolved through
## config.nims `--path:` override to the worktree nim-debra@0.8.0
## (registry-stale `debra-0.7.2` is intentionally bypassed). The
## 9 param-coherence guards from Doc C §3.0.2.4 apply to BOTH branches
## via the lifted `assertQueueParams` template.
##
## **Nim translation of Doc C §3.0.2.4 guards:** Doc C writes the 9
## param-coherence guards as `static: assert COND, MSG` statements at
## the top of each `when RK` branch of the object body. Nim does not
## accept `static:` blocks (nor `{.error.}` pragmas) directly inside
## an object type body, so the guards are lifted into a sibling
## generic template `assertQueueParams` invoked by the generic
## `validateQueueParams` proc that callers must use as the entry
## point for type validation. The condition expressions and error
## messages are byte-identical with Doc C §3.0.2.4; only the syntactic
## wrapper differs. Track A4 will harden this with a `nim check`
## expected-fail shell harness.
##
## Param order is LOAD-BEARING (Doc C §3.0.1, §5):
##   T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads
##
## Doc C §3.0 (target shape), §3.0.1 (uniform generic), §3.0.2.4 (9
## param-coherence guards), §5 (verbatim source).

import ./strategy
import ./reclamation
import ./internal/pinscope_stub
import ./atomic_dsl
import ./backoff
import options

import ./exceptions
import ./typestates
import ./typestates/mpmc_cell
import ./typestates/mpsc_push
import ./typestates/mpsc_pop
import ./typestates/spmc_push
import ./typestates/spmc_pop
import ./typestates/mpmc_push
import ./typestates/mpmc_pop
import ./typestates/spsc_push
import ./typestates/spsc_pop

# nim-debra 0.8.0 surface for the rkEbr field-decl block. Selective
# `from ... import` (qualified-only for the cardinality enum) avoids an
# ambiguous-`PinScopeCardinality` collision with `./internal/pinscope_stub`,
# which keeps providing the unqualified phantom-param enum until a later
# Phase-3.3 step retires the stub. `debra.ccSingle` is used in the
# hard-coded mupsic-equiv `handle` field decl below; the Queue phantom
# params `ccProd`/`ccCons` remain stub-typed.
from debra import DebraManager, ThreadHandle, PinnedScope

export exceptions

# `stManual`, `stEager`, `rkNone`, `rkEbr`, `ccSingle`, `ccMulti` are
# enum members that travel with their enum type — they are visible to
# any module that imports `queue` (no individual re-export needed; Nim
# rejects per-member enum re-exports).
export
  DeallocationStrategy, ReclamationKind, PinScopeCardinality, Manual, Eager,
  DefaultDeallocationStrategy

const LockFreeQueuesAdvanceEvery* {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in the rkEbr Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
  ##
  ## Lifted from `unbounded_mupmuc.nim` and `unbounded_mupsic.nim` per
  ## impl plan §A2 Step 3a-bis. Track F deletes the per-family copies
  ## once the unified body lands; lockfreequeues.nim re-exports this
  ## symbol as part of F5.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

type
  Segment*[S: static int, T] = object
    ## Unified rkEbr segment placeholder — declared in queue.nim per Doc C
    ## §3.0 / §5 (the unified `Queue` owns its `Segment` type, distinct
    ## from the per-family `Segment`/`MPSCSegment`/`MPMCSegment` types
    ## that live alongside the legacy unbounded families and the
    ## `typestates/unbounded_*` scaffolding). The full field set
    ## (`data`, `next`, `head`, `tail`, plus per-cardinality `closed` /
    ## `committed` / `prevConsumerIdx` flags) is fleshed out by Track E
    ## constructors and push/pop bodies in Steps 3.3.2-3.3.4. For 3.3.1
    ## (field-decl unlock only) the type is intentionally empty so the
    ## `Queue` rkEbr branch's `Atomic[ptr Segment[S, T]]` fields type-
    ## check — the type is only referenced via `ptr`, never instantiated
    ## by value, until Track E lands.
    discard

  Queue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
  ] = object
    when RK == rkNone:
      # Bounded body field declarations — Doc C §3.0 / §5, Track B / Task B1.
      #
      # Field-layout split by cardinality:
      #   - SPSC (ccSingle × ccSingle): StorageN1[N, T] (N+1 slots, no
      #     per-slot seq counter); head/tail are `Atomic[int]`. Lifted
      #     verbatim from `sipsic.nim`.
      #   - All other bounded shapes (MPSC/SPMC/MPMC): MPMCCellArrayN[N, T]
      #     (Vyukov per-slot seq counters); head/tail are `Atomic[uint64]`.
      #     Lifted verbatim from `mupsic.nim` / `sipmuc.nim` / `mupmuc.nim`.
      #
      # The shared field prefix `head, tail, (storage|cells)` MUST stay in
      # lockstep with the corresponding typestate Base type's prefix —
      # offsetOf asserts after the type definition enforce this.
      when ccProd == ccSingle and ccCons == ccSingle:
        head* {.align: CacheLineBytes.}: Atomic[int]
        tail* {.align: CacheLineBytes.}: Atomic[int]
        storage*: StorageN1[N, T]
      else:
        head* {.align: CacheLineBytes.}: Atomic[uint64]
        tail* {.align: CacheLineBytes.}: Atomic[uint64]
        cells*: MPMCCellArrayN[N, T]
        when ccProd == ccMulti:
          producerThreadIds*: array[P, Atomic[int]]
        when ccCons == ccMulti:
          consumerThreadIds*: array[C, Atomic[int]]
    elif RK == rkEbr:
      # Unbounded body field declarations — Doc C §3.0 / §5, Track E.
      #
      # The 9 §3.0.2.4 param-coherence guards (3 rkEbr-side: `S > 0`,
      # `MaxThreads > 0`, `N == 0 and P == 0 and C == 0`) are lifted into
      # `assertQueueParams` below — they cannot live inline in the object
      # body because Nim rejects `static: assert` blocks inside an
      # object type body (see the module docstring for the rationale).
      #
      # Field-layout cardinality variants (4 combos, matching Doc C §3.0):
      #   - ccSingle × ccSingle (sipsic-equivalent shape; rkEbr instantiable
      #     for type-uniformity even though `UnboundedSipsic` proper stays
      #     a separate type per Doc C §3.0.3 — base fields only).
      #   - ccMulti  × ccSingle (mupsic-equiv): + `producerCount` +
      #     single-consumer `handle: ThreadHandle[MaxThreads, ccSingle]`
      #     on the queue.
      #   - ccSingle × ccMulti  (sipmuc-equiv): + `consumerCount` +
      #     per-consumer `consumerHeads` array.
      #   - ccMulti  × ccMulti  (mupmuc-equiv): + `producerCount` +
      #     `consumerCount` + `consumerHeads` array.
      #
      # `Segment[S, T]` is the unified queue-owned placeholder declared
      # above; Track E (Steps 3.3.2-3.3.4) fleshes out its field set as
      # constructors and push/pop bodies land. `DebraManager` /
      # `ThreadHandle` resolve through `from debra import ...` at the
      # top of the module (config.nims `--path:` routes to the worktree
      # nim-debra@0.8.0). `CacheLineBytes` is re-exported by `./atomic_dsl`
      # via `debra/atomics`.
      #
      # The hard-coded `debra.ccSingle` in the `handle` field decl is
      # qualified because the unqualified `ccSingle` in this module
      # resolves to `./internal/pinscope_stub.ccSingle` (which is a
      # different enum type from `debra.PinScopeCardinality.ccSingle`);
      # `ThreadHandle` expects the debra-typed cardinality.
      manager*: ptr DebraManager[MaxThreads]
      headSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      tailSegment* {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
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
## Doc C §3.0.2.4 param-coherence guards.
##
## The condition expressions and error message strings are verbatim from
## Doc C §3.0.2.4. The Nim syntactic wrapper differs only because the
## design doc's `static: assert` notation is not legal inside an object
## type body in Nim; the assertions are lifted into a generic template
## and exercised via `validateQueueParams`.
## ----------------------------------------------------------------------

template assertQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
]() =
  when RK == rkNone:
    # 6 rkNone guards — Doc C §3.0.2.4.
    static:
      assert N > 0, "Queue[..., RK=rkNone] requires N > 0 (bounded slot count)"
    static:
      assert S == 0 and MaxThreads == 0,
        "Queue[..., RK=rkNone] must have S=0, MaxThreads=0 " &
          "(segment-size and thread-registry are rkEbr-only)"
    when ccProd == ccMulti:
      static:
        assert P > 0,
          "Queue[..., ccProd=ccMulti, RK=rkNone] requires P > 0 " &
            "(per-producer state count)"
    when ccProd == ccSingle:
      static:
        assert P == 0, "Queue[..., ccProd=ccSingle, RK=rkNone] must have P == 0"
    when ccCons == ccMulti:
      static:
        assert C > 0,
          "Queue[..., ccCons=ccMulti, RK=rkNone] requires C > 0 " &
            "(per-consumer state count)"
    when ccCons == ccSingle:
      static:
        assert C == 0, "Queue[..., ccCons=ccSingle, RK=rkNone] must have C == 0"
  elif RK == rkEbr:
    # 3 rkEbr guards — Doc C §3.0.2.4.
    static:
      assert S > 0, "Queue[..., RK=rkEbr] requires S > 0 (segment slot count)"
    static:
      assert MaxThreads > 0,
        "Queue[..., RK=rkEbr] requires MaxThreads > 0 " &
          "(debra thread-registry capacity)"
    static:
      assert N == 0 and P == 0 and C == 0,
        "Queue[..., RK=rkEbr] must have N=0, P=0, C=0 " &
          "(bounded slot/per-producer/per-consumer counts are rkNone-only)"

proc validateQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
](_: typedesc[Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]]) =
  ## Compile-time entry point for Doc C §3.0.2.4 param-coherence guards.
  ##
  ## Call this once per `Queue[...]` instantiation (the future
  ## constructors and method bodies in Tracks B/E will invoke it
  ## implicitly). For the A2 type-shell, smoke tests call it explicitly
  ## to exercise the 9 guards. Has no runtime cost — the body collapses
  ## to a single `discard` after the template's `static: assert`s fire.
  assertQueueParams[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]()
  discard

## ----------------------------------------------------------------------
## Bounded body (RK = rkNone) — Track B / Task B1.
##
## Field offsets shared with the typestate Base types live in the
## following `static:` block (sound per Doc C §3.0 — see also the
## offsetOf asserts in the legacy `mupsic.nim` / `sipmuc.nim` /
## `mupmuc.nim` / `sipsic.nim` modules; the unified Queue inherits the
## same field prefix so the same casts remain sound).
##
## Vyukov per-slot `seq` protocol is preserved byte-for-byte from the
## legacy bodies — the cardinality-specific paths simply dispatch via
## `when ccProd == ...` and `when ccCons == ...` ladders into the
## existing `{mpsc,spmc,mpmc,spsc}_{push,pop}` typestate verbs.
## ----------------------------------------------------------------------

# offsetOf casts soundness: pin shared prefix for each cardinality at
# a canonical instantiation. Object-field offsets are computed
# structurally, so a match for one instantiation implies a match for
# all (see legacy `mupsic.nim` lines 60-72 for the original rationale).
static:
  # SPSC (ccSingle × ccSingle) shares head/tail/storage with SipsicBase.
  doAssert offsetOf(
    Queue[int, ccSingle, ccSingle, stEager, rkNone, 8, 0, 0, 0, 0], head
  ) == offsetOf(SipsicBase[8, int], head)
  doAssert offsetOf(
    Queue[int, ccSingle, ccSingle, stEager, rkNone, 8, 0, 0, 0, 0], tail
  ) == offsetOf(SipsicBase[8, int], tail)
  doAssert offsetOf(
    Queue[int, ccSingle, ccSingle, stEager, rkNone, 8, 0, 0, 0, 0], storage
  ) == offsetOf(SipsicBase[8, int], storage)

  # MPSC (ccMulti × ccSingle) shares head/tail/cells with
  # MupsicPushBase / MupsicBase.
  doAssert offsetOf(Queue[int, ccMulti, ccSingle, stEager, rkNone, 8, 4, 0, 0, 0], head) ==
    offsetOf(MupsicPushBase[8, 4, int], head)
  doAssert offsetOf(Queue[int, ccMulti, ccSingle, stEager, rkNone, 8, 4, 0, 0, 0], tail) ==
    offsetOf(MupsicPushBase[8, 4, int], tail)
  doAssert offsetOf(
    Queue[int, ccMulti, ccSingle, stEager, rkNone, 8, 4, 0, 0, 0], cells
  ) == offsetOf(MupsicPushBase[8, 4, int], cells)
  doAssert offsetOf(Queue[int, ccMulti, ccSingle, stEager, rkNone, 8, 4, 0, 0, 0], head) ==
    offsetOf(MupsicBase[8, 4, int], head)
  doAssert offsetOf(Queue[int, ccMulti, ccSingle, stEager, rkNone, 8, 4, 0, 0, 0], tail) ==
    offsetOf(MupsicBase[8, 4, int], tail)
  doAssert offsetOf(
    Queue[int, ccMulti, ccSingle, stEager, rkNone, 8, 4, 0, 0, 0], cells
  ) == offsetOf(MupsicBase[8, 4, int], cells)

  # SPMC (ccSingle × ccMulti) shares head/tail/cells with
  # SipmucPushBase / SipmucBase.
  doAssert offsetOf(Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0], head) ==
    offsetOf(SipmucPushBase[8, 4, int], head)
  doAssert offsetOf(Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0], tail) ==
    offsetOf(SipmucPushBase[8, 4, int], tail)
  doAssert offsetOf(
    Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0], cells
  ) == offsetOf(SipmucPushBase[8, 4, int], cells)
  doAssert offsetOf(Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0], head) ==
    offsetOf(SipmucBase[8, 4, int], head)
  doAssert offsetOf(Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0], tail) ==
    offsetOf(SipmucBase[8, 4, int], tail)
  doAssert offsetOf(
    Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0], cells
  ) == offsetOf(SipmucBase[8, 4, int], cells)

  # MPMC (ccMulti × ccMulti) shares head/tail/cells with
  # MupmucPushBase / MupmucBase.
  doAssert offsetOf(Queue[int, ccMulti, ccMulti, stEager, rkNone, 8, 4, 4, 0, 0], head) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], head)
  doAssert offsetOf(Queue[int, ccMulti, ccMulti, stEager, rkNone, 8, 4, 4, 0, 0], tail) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], tail)
  doAssert offsetOf(Queue[int, ccMulti, ccMulti, stEager, rkNone, 8, 4, 4, 0, 0], cells) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], cells)
  doAssert offsetOf(Queue[int, ccMulti, ccMulti, stEager, rkNone, 8, 4, 4, 0, 0], head) ==
    offsetOf(MupmucBase[8, 4, 4, int], head)
  doAssert offsetOf(Queue[int, ccMulti, ccMulti, stEager, rkNone, 8, 4, 4, 0, 0], tail) ==
    offsetOf(MupmucBase[8, 4, 4, int], tail)
  doAssert offsetOf(Queue[int, ccMulti, ccMulti, stEager, rkNone, 8, 4, 4, 0, 0], cells) ==
    offsetOf(MupmucBase[8, 4, 4, int], cells)

const NoSlice* = none(HSlice[int, int])

type
  QueueProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
  ] = object
    ## Per-thread producer handle for a unified Queue. Retrieved via
    ## `Queue.getProducer()`. Defined for every (ccProd, ccCons) shape
    ## for type uniformity; only meaningful when `ccProd == ccMulti`
    ## (single-producer cardinalities push directly through
    ## `Queue.push`).
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]

  QueueConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
  ] = object
    ## Per-thread consumer handle for a unified Queue. Retrieved via
    ## `Queue.getConsumer()`. Defined for every (ccProd, ccCons) shape
    ## for type uniformity; only meaningful when `ccCons == ccMulti`
    ## (single-consumer cardinalities pop directly through `Queue.pop`).
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]

proc clear[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]) =
  when ccProd == ccSingle and ccCons == ccSingle:
    self.head.store(0, moRelaxed)
    self.tail.store(0, moRelaxed)
    self.storage.init()
  else:
    self.head.store(0'u64, moRelaxed)
    self.tail.store(0'u64, moRelaxed)
    self.cells.init()
    when ccProd == ccMulti:
      for p in 0 ..< P:
        self.producerThreadIds[p].store(0, moRelaxed)
    when ccCons == ccMulti:
      for c in 0 ..< C:
        self.consumerThreadIds[c].store(0, moRelaxed)

proc initQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    N, P, C: static int,
](): Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0] =
  ## Bounded-queue constructor (Doc C §5, Q6 — ST has proc-level default).
  ## Initializes the slot storage, zeroes head/tail, and clears any
  ## producer/consumer thread-id registry tables (multi-cardinality only).
  validateQueueParams(Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0])
  result.clear()

proc capacity*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N

proc producerCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]): int {.inline.} =
  ## Returns the queue's producer-registry capacity (`P`).
  ## Single-producer shapes report 0.
  result = P

proc consumerCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]): int {.inline.} =
  ## Returns the queue's consumer-registry capacity (`C`).
  ## Single-consumer shapes report 0.
  result = C

## ----------------------------------------------------------------------
## getProducer / getConsumer — multi-cardinality thread-id registration.
##
## These procs are defined only for the multi-cardinality side
## (`ccProd == ccMulti` resp. `ccCons == ccMulti`). The single-
## cardinality side pushes/pops directly through `Queue.push` /
## `Queue.pop` (no handshake required). Migrated verbatim from
## `mupsic.nim` / `sipmuc.nim` / `mupmuc.nim`.
## ----------------------------------------------------------------------

proc getProducer*[
    T;
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](
    self: var Queue[T, ccMulti, ccCons, ST, rkNone, N, P, C, 0, 0], idx: int = -1
): QueueProducer[T, ccMulti, ccCons, ST, rkNone, N, P, C, 0, 0] {.
    raises: [NoProducersAvailableError]
.} =
  ## Assigns and returns a `QueueProducer` for the current thread.
  ## When `idx >= 0`, the caller pins a specific producer slot
  ## (testing). When `idx == -1`, the thread's `getThreadId()` is
  ## stored into the first free slot via a CAS over `producerThreadIds`.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> producerIdx
  for i in 0 ..< P:
    if self.producerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping
  for i in 0 ..< P:
    var expected = 0
    if self.producerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  raise newException(
    NoProducersAvailableError,
    "All producers have been assigned. " &
      "Increase your producer count (P) or setMaxPoolSize(P).",
  )

proc getConsumer*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, rkNone, N, P, C, 0, 0], idx: int = -1
): QueueConsumer[T, ccProd, ccMulti, ST, rkNone, N, P, C, 0, 0] {.
    raises: [NoConsumersAvailableError]
.} =
  ## Assigns and returns a `QueueConsumer` for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  let threadId = getThreadId()

  for i in 0 ..< C:
    if self.consumerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  for i in 0 ..< C:
    var expected = 0
    if self.consumerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  raise newException(NoConsumersAvailableError, "All consumers assigned")

## ----------------------------------------------------------------------
## push / pop — cardinality-dispatched Vyukov / Sipsic logic.
##
## Single-item push:
##   - SPSC (ccSingle × ccSingle):   Queue.push(item)        -> spsc_push
##   - MPSC (ccMulti  × ccSingle):   producer.push(item)     -> mpsc_push
##   - SPMC (ccSingle × ccMulti):    Queue.push(item)        -> spmc_push
##   - MPMC (ccMulti  × ccMulti):    producer.push(item)     -> mpmc_push
##
## Single-item pop:
##   - SPSC:                          Queue.pop()             -> spsc_pop
##   - MPSC:                          Queue.pop()             -> mpsc_pop
##   - SPMC:                          consumer.pop()          -> spmc_pop
##   - MPMC:                          consumer.pop()          -> mpmc_pop
##
## Each path is byte-for-byte identical with the legacy bodies — only
## the surrounding wrapper differs (the cast target is the same
## typestate Base type, gated by the offsetOf asserts above).
## ----------------------------------------------------------------------

# --- SPSC push (direct on Queue) -----------------------------------------
proc push*[T; ST: static DeallocationStrategy, N: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, rkNone, N, 0, 0, 0, 0], item: T
): bool =
  ## SPSC single-item push (lock-free; uses the SPSC typestate verbs).
  ## Migrated from `sipsic.nim`.
  var queueBase = cast[ptr SipsicBase[N, T]](addr self)

  let op = spsc_push.start[N]()
  let loaded = op.loadPointers(queueBase[])
  var fullCheck = loaded.checkFull()

  match fullCheck:
    SPSCPushFull(full):
      return full.extractFalse()
    SPSCPushNotFull(notFull):
      return notFull.writeData(queueBase[], item).complete(queueBase[])

# --- SPMC push (direct on Queue; single producer side) -------------------
proc push*[T; ST: static DeallocationStrategy, N, C: static int](
    self: var Queue[T, ccSingle, ccMulti, ST, rkNone, N, 0, C, 0, 0], item: T
): bool =
  ## SPMC single-item push (defensive CAS, single-producer-side).
  ## Migrated from `sipmuc.nim`.
  var queueBase = cast[ptr SipmucPushBase[N, C, T]](addr self)

  var op = spmc_push.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      SPMCPushFull(full):
        return full.extractFalse()
      SPMCPushSlotClaimed(slotClaimed):
        return slotClaimed.complete(queueBase[], item)
      SPMCPushStart(restart):
        op = restart
        backoffOnRetry(spins)
        continue

# --- MPSC push (via QueueProducer) ---------------------------------------
proc push*[T; ST: static DeallocationStrategy, N, P: static int](
    self: QueueProducer[T, ccMulti, ccSingle, ST, rkNone, N, P, 0, 0, 0], item: T
): bool =
  ## MPSC single-item push (lock-free; uses the MPSC typestate verbs).
  ## Migrated from `mupsic.nim`.
  var queueBase = cast[ptr MupsicPushBase[N, P, T]](self.queue)

  var op = mpsc_push.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPSCPushFull(full):
        return full.extractFalse()
      MPSCPushSlotClaimed(slotClaimed):
        return slotClaimed.complete(queueBase[], item)
      MPSCPushStart(restart):
        op = restart
        backoffOnRetry(spins)
        continue

# --- MPMC push (via QueueProducer) ---------------------------------------
proc push*[T; ST: static DeallocationStrategy, N, P, C: static int](
    self: QueueProducer[T, ccMulti, ccMulti, ST, rkNone, N, P, C, 0, 0], item: T
): bool =
  ## MPMC single-item push (lock-free; uses the MPMC typestate verbs).
  ## Migrated from `mupmuc.nim`.
  var queueBase = cast[ptr MupmucPushBase[N, P, C, T]](self.queue)

  var op = mpmc_push.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPMCPushFull(full):
        return full.extractFalse()
      MPMCPushSlotClaimed(slotClaimed):
        return slotClaimed.complete(queueBase[], item)
      MPMCPushStart(restart):
        op = restart
        backoffOnRetry(spins)
        continue

# --- ccMulti-producer trap on bare Queue.push ----------------------------
# Mirror the legacy Mupsic/Mupmuc bare-receiver `push` that raises
# InvalidCallDefect to steer callers toward `producer.push`.
proc push*[
    T;
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](self: var Queue[T, ccMulti, ccCons, ST, rkNone, N, P, C, 0, 0], item: T): bool =
  ## Raises `InvalidCallDefect`. Use `QueueProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use QueueProducer.push()")

# --- SPSC pop (direct on Queue) ------------------------------------------
proc pop*[T; ST: static DeallocationStrategy, N: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, rkNone, N, 0, 0, 0, 0]
): Option[T] =
  ## SPSC single-item pop. Migrated from `sipsic.nim`.
  var queueBase = cast[ptr SipsicBase[N, T]](addr self)

  let op = spsc_pop.start[N]()
  let loaded = op.loadPointers(queueBase[])
  var emptyCheck = loaded.checkEmpty()

  match emptyCheck:
    SPSCPopEmpty(_):
      return none(T)
    SPSCPopNotEmpty(notEmpty):
      return some(notEmpty.complete(queueBase[]))

# --- MPSC pop (direct on Queue; single consumer side) --------------------
proc pop*[T; ST: static DeallocationStrategy, N, P: static int](
    self: var Queue[T, ccMulti, ccSingle, ST, rkNone, N, P, 0, 0, 0]
): Option[T] =
  ## MPSC single-item pop (defensive CAS, single-consumer-side).
  ## Migrated from `mupsic.nim`.
  var queueBase = cast[ptr MupsicBase[N, P, T]](addr self)

  var op = mpsc_pop.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPSCPopEmpty(_):
        return none(T)
      MPSCPopSlotClaimed(slotClaimed):
        return some(slotClaimed.complete(queueBase[]))
      MPSCPopStart(restart):
        op = restart
        backoffOnRetry(spins)
        continue

# --- SPMC pop (via QueueConsumer) ----------------------------------------
proc pop*[T; ST: static DeallocationStrategy, N, C: static int](
    self: QueueConsumer[T, ccSingle, ccMulti, ST, rkNone, N, 0, C, 0, 0]
): Option[T] =
  ## SPMC single-item pop (lock-free; uses the SPMC typestate verbs).
  ## Migrated from `sipmuc.nim`.
  var queueBase = cast[ptr SipmucBase[N, C, T]](self.queue)

  var op = spmc_pop.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      SPMCPopEmpty(_):
        return none(T)
      SPMCPopSlotClaimed(slotClaimed):
        return some(slotClaimed.complete(queueBase[]))
      SPMCPopStart(restart):
        op = restart
        backoffOnRetry(spins)
        continue

# --- MPMC pop (via QueueConsumer) ----------------------------------------
proc pop*[T; ST: static DeallocationStrategy, N, P, C: static int](
    self: QueueConsumer[T, ccMulti, ccMulti, ST, rkNone, N, P, C, 0, 0]
): Option[T] =
  ## MPMC single-item pop (lock-free; uses the MPMC typestate verbs).
  ## Migrated from `mupmuc.nim`.
  var queueBase = cast[ptr MupmucBase[N, P, C, T]](self.queue)

  var op = mpmc_pop.start[N]()
  var spins = InitialSpin
  while true:
    var claim = op.tryClaim(queueBase[])
    match claim:
      MPMCPopEmpty(_):
        return none(T)
      MPMCPopSlotClaimed(slotClaimed):
        return some(slotClaimed.complete(queueBase[]))
      MPMCPopStart(restart):
        op = restart
        backoffOnRetry(spins)
        continue

# --- ccMulti-consumer trap on bare Queue.pop -----------------------------
# Mirror the legacy Sipmuc/Mupmuc bare-receiver `pop` that raises
# InvalidCallDefect to steer callers toward `consumer.pop`.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](self: var Queue[T, ccProd, ccMulti, ST, rkNone, N, P, C, 0, 0]): Option[T] =
  ## Raises `InvalidCallDefect`. Use `QueueConsumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use QueueConsumer.pop()")

## ----------------------------------------------------------------------
## Batch push / pop — `openArray` and `count`-style overloads.
##
## Like the legacy bodies, batch operations are best-effort loops over
## single-item primitives. Lock-free guarantees on a per-item basis;
## batch atomicity is intentionally NOT preserved (semantic change
## documented in the legacy 3.x→4.x migration notes).
## ----------------------------------------------------------------------

# --- SPSC batch push (direct on Queue) -----------------------------------
proc push*[T; ST: static DeallocationStrategy, N: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, rkNone, N, 0, 0, 0, 0],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## SPSC batch push. Migrated from `sipsic.nim`.
  if unlikely(items.len == 0):
    return NoSlice

  let tail = loadAcquireN1[N](self.tail).validate()
  let head = loadSequentialN1[N](self.head).validate()

  if unlikely(fullN1(head, tail)):
    return some(0 .. items.len - 1)

  let avail = availableN1(head, tail)
  var count: int

  if likely(avail >= items.len):
    result = NoSlice
    count = items.len
  else:
    result = some(avail .. items.len - 1)
    count = min(avail, N)

  for i in 0 ..< count:
    let currentTail = tail.incOrResetN1(i)
    self.storage[currentTail.index()] = items[i]

  let newTail = tail.incOrResetN1(count)
  self.tail.storeReleaseN1(newTail)

# --- SPMC batch push (direct on Queue) -----------------------------------
proc push*[T; ST: static DeallocationStrategy, N, C: static int](
    self: var Queue[T, ccSingle, ccMulti, ST, rkNone, N, 0, C, 0, 0],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## SPMC batch push (loop of single-item pushes).
  ## Migrated from `sipmuc.nim`.
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

# --- MPSC batch push (via QueueProducer) ---------------------------------
proc push*[T; ST: static DeallocationStrategy, N, P: static int](
    self: QueueProducer[T, ccMulti, ccSingle, ST, rkNone, N, P, 0, 0, 0],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## MPSC batch push (loop of single-item pushes).
  ## Migrated from `mupsic.nim`.
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

# --- MPMC batch push (via QueueProducer) ---------------------------------
proc push*[T; ST: static DeallocationStrategy, N, P, C: static int](
    self: QueueProducer[T, ccMulti, ccMulti, ST, rkNone, N, P, C, 0, 0],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## MPMC batch push (loop of single-item pushes).
  ## Migrated from `mupmuc.nim`.
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

# --- ccMulti-producer trap on bare Queue.push openArray ------------------
proc push*[
    T;
    ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](
    self: var Queue[T, ccMulti, ccCons, ST, rkNone, N, P, C, 0, 0], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Raises `InvalidCallDefect`. Use `QueueProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use QueueProducer.push()")

# --- SPSC batch pop (direct on Queue) ------------------------------------
proc pop*[T; ST: static DeallocationStrategy, N: static int](
    self: var Queue[T, ccSingle, ccSingle, ST, rkNone, N, 0, 0, 0, 0], count: int
): Option[seq[T]] =
  ## SPSC batch pop. Migrated from `sipsic.nim`.
  let head = loadAcquireN1[N](self.head).validate()
  let tail = loadSequentialN1[N](self.tail).validate()

  let usedCount = usedN1(head, tail)
  var actualCount: int

  if likely(usedCount >= count):
    actualCount = count
  elif usedCount <= 0:
    return none(seq[T])
  else:
    actualCount = min(usedCount, N)

  var res = newSeq[T](actualCount)

  for i in 0 ..< actualCount:
    let currentHead = head.incOrResetN1(i)
    res[i] = self.storage[currentHead.index()]

  result = some(res)
  let newHead = head.incOrResetN1(actualCount)
  self.head.storeReleaseN1(newHead)

# --- MPSC batch pop (direct on Queue) ------------------------------------
proc pop*[T; ST: static DeallocationStrategy, N, P: static int](
    self: var Queue[T, ccMulti, ccSingle, ST, rkNone, N, P, 0, 0, 0], count: int
): Option[seq[T]] =
  ## MPSC batch pop (loop of single-item pops). Migrated from `mupsic.nim`.
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

# --- SPMC batch pop (via QueueConsumer) ----------------------------------
proc pop*[T; ST: static DeallocationStrategy, N, C: static int](
    self: QueueConsumer[T, ccSingle, ccMulti, ST, rkNone, N, 0, C, 0, 0], count: int
): Option[seq[T]] =
  ## SPMC batch pop (loop of single-item pops). Migrated from `sipmuc.nim`.
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

# --- MPMC batch pop (via QueueConsumer) ----------------------------------
proc pop*[T; ST: static DeallocationStrategy, N, P, C: static int](
    self: QueueConsumer[T, ccMulti, ccMulti, ST, rkNone, N, P, C, 0, 0], count: int
): Option[seq[T]] =
  ## MPMC batch pop (loop of single-item pops). Migrated from `mupmuc.nim`.
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

# --- ccMulti-consumer trap on bare Queue.pop count -----------------------
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    N, P, C: static int,
](
    self: var Queue[T, ccProd, ccMulti, ST, rkNone, N, P, C, 0, 0], count: int
): Option[seq[T]] =
  ## Raises `InvalidCallDefect`. Use `QueueConsumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use QueueConsumer.pop()")

when defined(testing):
  from unittest import check

  proc reset*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      N, P, C: static int,
  ](self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]) =
    ## Resets the queue to its default state. For single-threaded unit
    ## tests only.
    self.clear()

  proc checkState*[T; ST: static DeallocationStrategy, N: static int](
      self: var Queue[T, ccSingle, ccSingle, ST, rkNone, N, 0, 0, 0, 0],
      head: int,
      tail: int,
      storage: seq[T],
  ) =
    ## SPSC `checkState` — migrated from `sipsic.nim`.
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 .. N:
      if i < storage.len:
        check(self.storage.data[i] == storage[i])

  proc checkState*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      N, P, C: static int,
  ](
      self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0],
      head: uint64,
      tail: uint64,
  ) =
    ## Non-SPSC head+tail-only `checkState` — migrated from
    ## `mupsic.nim` / `sipmuc.nim` / `mupmuc.nim`.
    when ccProd == ccSingle and ccCons == ccSingle:
      {.
        error:
          "checkState(uint64) not applicable to SPSC; use the int " & "+ seq[T] overload"
      .}
    else:
      check(self.head.load(moRelaxed) == head)
      check(self.tail.load(moRelaxed) == tail)

  proc checkState*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      ST: static DeallocationStrategy,
      N, P, C: static int,
  ](
      self: var Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0],
      head: uint64,
      tail: uint64,
      data: seq[T],
  ) =
    ## Non-SPSC head+tail+data `checkState` — migrated from
    ## `mupsic.nim` / `sipmuc.nim` / `mupmuc.nim`.
    when ccProd == ccSingle and ccCons == ccSingle:
      {.
        error:
          "checkState(uint64, seq[T]) not applicable to SPSC; use the " &
          "int + seq[T] overload"
      .}
    else:
      check(self.head.load(moRelaxed) == head)
      check(self.tail.load(moRelaxed) == tail)
      for i in 0 ..< N:
        check(self.cells.cells[i].payload.data == data[i])
