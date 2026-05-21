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
import ./internal/aligned_alloc
import ./atomic_dsl
import ./backoff
import options
import std/typetraits

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
#
# Step 3.3.2 adds `initDebraManager`, `registerThread`, `bindClient`,
# `unbindClient` for the rkEbr constructor / destructor surface. Each
# symbol is named individually (rather than `import debra`) to keep
# `debra.PinScopeCardinality` qualified-only and avoid colliding with
# the stub enum.
from debra import
  DebraManager, ThreadHandle, PinnedScope, initDebraManager, registerThread, bindClient,
  unbindClient, unpinned, pinScope

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
  Segment*[T; ccProd, ccCons: static PinScopeCardinality, S: static int] = object
    ## Unified rkEbr segment — declared in queue.nim per Doc C §3.0 / §5.
    ## The unified `Queue` owns its `Segment` type, distinct from the
    ## per-family `Segment` types in the legacy `unbounded_*.nim` files.
    ##
    ## Parameterized by `ccProd` / `ccCons` so each cardinality variant's
    ## field set matches its per-family analogue verbatim (lifted from
    ## the legacy sources):
    ##   - `data: array[S, T]` — slot storage (all variants).
    ##   - `next: Atomic[ptr Segment[...]]` — linked-list pointer (all
    ##     variants).
    ##   - `tail`: producer write index. Atomic[int] for multi-producer
    ##     (CAS-coordinated) and for sipsic-equiv (publish via release
    ##     store). Lifted from `unbounded_{mupsic,sipmuc,mupmuc,sipsic}.nim`.
    ##   - `head: int` — single-consumer non-atomic read position
    ##     (mupsic-equiv only). Lifted from `unbounded_mupsic.nim:72`.
    ##   - `committed: array[S, Atomic[bool]]` — multi-producer
    ##     publication flags (mupsic-equiv + mupmuc-equiv). Lifted from
    ##     `unbounded_mupsic.nim:78` / `unbounded_mupmuc.nim:72`.
    ##   - `prevConsumerIdx: Atomic[int]` — multi-consumer CAS slot
    ##     (sipmuc-equiv + mupmuc-equiv). Lifted from
    ##     `unbounded_sipmuc.nim:74` / `unbounded_mupmuc.nim:70`.
    ##
    ## Step 3.3.3 introduces the field set and allocates via
    ## `newSegment[T, ccProd, ccCons, S]()` on the push growth path.
    ## Step 3.3.4 wires up pop-side retire (`segmentDestructor`).
    data*: array[S, T]
    next* {.align: CacheLineBytes.}: Atomic[ptr Segment[T, ccProd, ccCons, S]]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    when ccProd == ccMulti and ccCons == ccSingle:
      # mupsic-equiv: single-consumer non-atomic read position. Aligned
      # to its own cache line so the consumer's `head` writes do not
      # invalidate producers' cached `tail` line (legacy:
      # `unbounded_mupsic.nim:72`).
      head* {.align: CacheLineBytes.}: int
    when ccProd == ccMulti:
      # mupsic-equiv + mupmuc-equiv: multi-producer publication flags
      # (legacy: `unbounded_mupsic.nim:78`, `unbounded_mupmuc.nim:72`).
      committed* {.align: CacheLineBytes.}: array[S, Atomic[bool]]
    when ccCons == ccMulti:
      # sipmuc-equiv + mupmuc-equiv: multi-consumer CAS coordination
      # (legacy: `unbounded_sipmuc.nim:74`, `unbounded_mupmuc.nim:70`).
      prevConsumerIdx* {.align: CacheLineBytes.}: Atomic[int]

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
    ## for type uniformity.
    ##
    ## For the rkEbr branch with `ccProd == ccMulti` (mupsic-equiv and
    ## mupmuc-equiv) the producer additionally carries its own
    ## `ThreadHandle[MaxThreads, debra.ccSingle]` — each producer
    ## thread owns its own handle for the pin/unpin cycle in `push`
    ## (§3.5.4 / §3.5.5 pin-only sites; mirrors
    ## `unbounded_mupmuc.nim:102` and `unbounded_mupsic.nim:109`).
    ## For `ccProd == ccSingle` the field is absent (sipsic-equiv has
    ## no EBR and sipmuc-equiv producer-push is also pin-free per
    ## `unbounded_sipmuc.nim:197`). For `RK == rkNone` (bounded) the
    ## field is absent (bounded queues have no debra integration).
    idx*: int
    queue*: ptr Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]
    when RK == rkEbr and ccProd == ccMulti:
      handle*: ThreadHandle[MaxThreads, debra.ccSingle]

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

## ----------------------------------------------------------------------
## Unbounded body (RK = rkEbr) — Track E / Step 3.3.2.
##
## Constructor / accessor / destructor surface for the rkEbr branch of
## the unified `Queue` generic per Doc C §3.0 + §3.1 / §5.
##
## **Two `newQueue` overloads** per Doc C §5:
##
##   1. **Manager-owning** — zero-arg `newQueue(typedesc[Queue[...]])`.
##      Allocates a heap `DebraManager[MaxThreads]` internally, registers
##      the calling thread (for the mupsic-equiv `handle` field), and
##      sets `ownsManager = true`. The queue's `=destroy` tears the
##      manager down (drains limbo bags, asserts `clientCount == 0`) and
##      frees the heap allocation.
##   2. **Manager-borrowed** — `newQueue(typedesc[Queue[...]], manager,
##      handle)`. Takes a `ptr DebraManager[MaxThreads]` plus the
##      consumer `ThreadHandle[MaxThreads, ccCons]` per Doc C §5. Sets
##      `ownsManager = false`. The queue's `=destroy` does NOT free the
##      manager; lifetime is the caller's responsibility. The handle
##      argument is consumed only by the mupsic-equiv variant
##      (`ccProd == ccMulti and ccCons == ccSingle`); other variants
##      accept the arg for signature uniformity (Doc C §5 prescribes one
##      borrow shape across all 4 rkEbr cardinality combos) and discard
##      it. Resolution: "least surprising" — match Doc C verbatim; the
##      handle drops onto the queue only when the queue actually has a
##      `handle` field. Step 3.3.3/3.3.4 may refine the per-cardinality
##      signature surface as push/pop bodies land.
##
## **`getProducer` / `getConsumer` accessors** are placeholders that
## return the existing `QueueProducer[..., rkEbr, ...]` /
## `QueueConsumer[..., rkEbr, ...]` shapes (defined for every RK for
## type uniformity). Per-thread debra-handle registration on the views
## is deferred to Step 3.3.3/3.3.4 when the push/pop bodies are wired
## up; the 3.3.2 stubs just return correctly-typed views with
## `queue = addr self` and `idx = -1`.
##
## **`=destroy`** walks the segment list (`headSegment` → `next` → ...
## free each), then unbinds the client from the manager. When
## `ownsManager`, additionally runs the manager's destructor and frees
## the heap slot; otherwise leaves the manager alone. Segments are not
## yet allocated by the 3.3.2 constructors (Step 3.3.3/3.3.4 fleshes
## out the Segment field set and segment-allocation paths), so the
## walk degenerates to a `nil` check and the manager-borrow correctness
## check exercises the `ownsManager == false` branch in isolation.
##
## Doc C §3.0 (target shape), §3.1 (constructor/accessor signatures),
## §5 (verbatim source).
## ----------------------------------------------------------------------

proc newSegment[T; ccProd, ccCons: static PinScopeCardinality, S: static int](): ptr Segment[
  T, ccProd, ccCons, S
] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## `{.align.}` pragmas on `next` / `tail` / `committed` /
  ## `prevConsumerIdx` land on distinct physical cache lines rather
  ## than sharing the 16-byte-aligned base that `c_calloc` returns.
  ##
  ## Lifted from `unbounded_mupmuc.nim:112-120`,
  ## `unbounded_mupsic.nim:111-119`, `unbounded_sipmuc.nim:109-115`,
  ## `unbounded_sipsic.nim:42-49`. The field-init set is the union of
  ## the per-family initializers, gated by `when` to match each
  ## cardinality's field presence.
  result = allocAligned[Segment[T, ccProd, ccCons, S]]()
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  when ccProd == ccMulti and ccCons == ccSingle:
    result.head = 0
  when ccProd == ccMulti:
    for i in 0 ..< S:
      result.committed[i].store(false, moRelaxed)
  when ccCons == ccMulti:
    result.prevConsumerIdx.store(-1, moRelaxed)

proc newQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]],
    manager: ptr DebraManager[MaxThreads],
    handle: ThreadHandle[MaxThreads, debra.ccSingle],
): Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads] =
  ## Manager-borrowed rkEbr `newQueue` overload (Doc C §3.1 / §5).
  ##
  ## Caller owns the `DebraManager` and is responsible for its lifetime;
  ## this queue records `ownsManager = false` and its `=destroy` will
  ## NOT tear the manager down. `bindClient` is still called so the
  ## manager's destructor can assert `clientCount == 0` and refuse to
  ## drop while clients remain bound.
  ##
  ## `handle` is consumed by the mupsic-equiv variant
  ## (`ccProd == ccMulti and ccCons == ccSingle`) which carries a
  ## queue-level consumer handle per Doc C §3.0. Other cardinality
  ## variants accept the arg for signature uniformity across the 4
  ## rkEbr combos and silently drop it. Resolution: "least surprising"
  ## — match Doc C §5 verbatim rather than splitting the borrow shape
  ## per-cardinality (Step 3.3.3/3.3.4 may refine).
  validateQueueParams(Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads])
  result.manager = manager
  result.ownsManager = false
  result.itemCount.store(0, moRelaxed)
  when ccProd == ccMulti:
    result.producerCount.store(0, moRelaxed)
  when ccCons == ccMulti:
    result.consumerCount.store(0, moRelaxed)
  when ccProd == ccMulti and ccCons == ccSingle:
    result.handle = handle
  else:
    discard handle
  # Step 3.3.3: allocate the initial `Segment[T, ccProd, ccCons, S]`
  # and publish on both `headSegment` and `tailSegment`. Lifted from
  # the legacy `newUnboundedMupmuc` (line 153-155), `newUnboundedMupsic`
  # (line 154-156), `newUnboundedSipmuc` (line 148-150), and
  # `newUnboundedSipsic` (line 69-71) constructors.
  let seg = newSegment[T, ccProd, ccCons, S]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.segments.store(1, moRelaxed)
  bindClient(manager[])

proc newQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy = DefaultDeallocationStrategy,
    S, MaxThreads: static int,
](
    _: typedesc[Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]]
): Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads] =
  ## Manager-owning rkEbr `newQueue` overload (Doc C §3.1 / §5).
  ##
  ## Heap-allocates a private `DebraManager[MaxThreads]`, registers the
  ## calling thread (yielding the consumer handle used by the mupsic-
  ## equiv variant), and records `ownsManager = true`. The queue's
  ## `=destroy` runs the manager's destructor (drains limbo bags,
  ## asserts `clientCount == 0`) and frees the heap slot.
  ##
  ## **Caller must be the consumer thread.** For the mupsic-equiv
  ## variant the manager-owning shape stores the consumer handle on the
  ## queue; constructing on a different thread than the future `pop`
  ## caller would mis-route the handle. Multi-queue / multi-thread
  ## setups should use the manager-borrowed overload with an explicit
  ## handle obtained on the consumer thread.
  ##
  ## Failure-path cleanup uses `finally` (not `except:`) so that
  ## `Defect`-class raises (e.g. `OutOfMemDefect` from
  ## `initDebraManager`) also free `mgr`. Pattern lifted verbatim from
  ## `unbounded_mupsic.nim` newUnboundedMupsic auto-create overload
  ## (which Track F retires once the unified body lands).
  validateQueueParams(Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads])
  let mgr = allocAligned[DebraManager[MaxThreads]]()
  var ok = false
  try:
    mgr[] = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(mgr[])
    result = newQueue(
      Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads], mgr, consumerHandle
    )
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
    self: var Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]
): QueueProducer[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads] =
  ## Returns a `QueueProducer` view bound to this rkEbr queue. For
  ## `ccProd == ccMulti` (mupsic-equiv + mupmuc-equiv) registers the
  ## calling thread against the queue's `DebraManager` and stores the
  ## resulting `ThreadHandle` on the producer view — the handle drives
  ## the §3.5.4 / §3.5.5 pin-only push sites in `push` below.
  ##
  ## Each call to the auto-register overload consumes one
  ## `DebraManager` thread slot; per the legacy contract
  ## (`unbounded_mupmuc.nim:213-225`) the slot is **not reclaimed** when
  ## the producer view is destroyed — it lives until the manager itself
  ## is destroyed. Long-running queues should reuse the same
  ## `QueueProducer` per thread.
  ##
  ## For `ccProd == ccSingle` (sipsic-equiv + sipmuc-equiv) the producer
  ## view carries no handle — single-producer push needs no pin.
  result.queue = addr(self)
  when ccProd == ccMulti:
    # Lift verbatim from `unbounded_mupmuc.nim:200-209` (manual-handle
    # path) + auto-register overload (`:211-224`): bump
    # `producerCount`, register thread, store handle. The fetchAdd is
    # moAcquire to publish the slot consumption to other producers.
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
    self: var Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]
): QueueConsumer[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads] =
  ## Returns a `QueueConsumer` view bound to this rkEbr queue. Step
  ## 3.3.2 placeholder — populates `queue` and a sentinel `idx`. Step
  ## 3.3.4 (pop body) wires up per-thread debra-handle registration
  ## semantics.
  result.queue = addr(self)
  result.idx = -1

## ----------------------------------------------------------------------
## rkEbr len / segmentCount accessors — Track E / Step 3.3.3.
##
## Lifted from `unbounded_mupmuc.nim:188-198` / `unbounded_mupsic.nim` /
## `unbounded_sipmuc.nim` / `unbounded_sipsic.nim`.
## ----------------------------------------------------------------------

proc len*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]): int =
  ## Number of items currently in the queue (atomic snapshot).
  result = self.itemCount.load(moRelaxed)

proc segmentCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]): int =
  ## Number of segments currently allocated (atomic snapshot).
  result = self.segments.load(moRelaxed)

## ----------------------------------------------------------------------
## rkEbr push body — Track E / Step 3.3.3.
##
## Doc C §3.5 carrier decision: push lives on `QueueProducer[..., rkEbr,
## ...]` across all 4 cardinality variants (sipsic-equiv, sipmuc-equiv,
## mupsic-equiv, mupmuc-equiv). The `getProducer` accessor returns a
## producer view in every variant for type uniformity; single-producer
## variants (sipsic-equiv, sipmuc-equiv) get a no-handle producer and
## a no-pin push path, while multi-producer variants (mupsic-equiv,
## mupmuc-equiv) get a `ThreadHandle`-carrying producer that drives the
## §3.5.4 / §3.5.5 pin-only sites.
##
## **§3.5.6 Pin-Claim Ordering invariant** (load-bearing): for the
## multi-producer variants the `pinScope(unpinned(self.handle))` call
## happens BEFORE any segment-pointer load (`self.queue.tailSegment.
## load(...)`). The pin acquisition publishes the producer's epoch
## subscription onto the manager so a consumer cannot reclaim the
## segment between our load and our slot CAS. Lifted verbatim from
## `unbounded_mupmuc.nim:268-312` and `unbounded_mupsic.nim:252-297`;
## the only structural change from `self.handle.withPin: ...` to
## `var scope = pinScope(unpinned(self.handle))` is the RAII shape
## (block exit / `=destroy` drives the unpin chain rather than the
## `withPin` template's deferred unpin).
##
## The two pin-only sites (§3.5.4 mupsic-equiv + §3.5.5 mupmuc-equiv)
## do NOT retire any segment in `push`; segment retire is the consumer's
## job in `pop` (Step 3.3.4). `scope` is constructed but `scope.state`
## is never used directly — the value's presence on the stack is
## sufficient to keep the pin alive, and the destructor drives the
## unpin at scope exit on every path (normal return, `break`-from-loop,
## raise — though push body is `{.raises: [].}` so no raise path
## exists). typestates 0.9.2's CFG analyzer accepts the pattern via the
## `=destroy` `{.destructorTransition: PinnedScopeAlive ->
## PinnedScopeDestroyed.}` registration in
## `nim-debra/src/debra/typestates/pinned_scope.nim:180`.
## ----------------------------------------------------------------------

proc push*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var QueueProducer[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads],
    item: T,
) {.raises: [].} =
  ## Push a single item onto the unbounded queue. Never blocks; never
  ## fails (the queue grows by segment allocation on the slow path).
  ##
  ## Per-cardinality dispatch:
  ##   - **ccSingle × ccSingle** (sipsic-equiv): no pin, no CAS. Lifted
  ##     from `unbounded_sipsic.nim:83-115`. Note: per Doc C §3.0.3 the
  ##     canonical SPSC unbounded queue is `UnboundedSipsic` — this
  ##     `Queue[..., ccSingle, ccSingle, rkEbr, ...]` shape is
  ##     instantiable for type-uniformity but `UnboundedSipsic` is the
  ##     production-recommended type.
  ##   - **ccSingle × ccMulti** (sipmuc-equiv): no pin (single
  ##     producer), simple `tailSegment` advance with release publish.
  ##     Lifted from `unbounded_sipmuc.nim:197-229`. `tailSegment` is
  ##     atomic on the unified Queue (uniform field declaration across
  ##     cardinalities) where the legacy sipmuc had a non-atomic
  ##     `tailSegment: ptr Segment[...]` — single-producer use means
  ##     the only writer is this thread, so the legacy ordering is
  ##     preserved with `moRelaxed` loads and `moRelease` stores on
  ##     the unified atomic.
  ##   - **ccMulti × ccSingle** (mupsic-equiv): pin via
  ##     `pinScope(unpinned(self.handle))`, CAS slot claim with
  ##     segment growth on full. §3.5.4 pin-only site. Lifted verbatim
  ##     from `unbounded_mupsic.nim:252-297`.
  ##   - **ccMulti × ccMulti** (mupmuc-equiv): pin via
  ##     `pinScope(unpinned(self.handle))`, CAS slot claim with
  ##     segment growth on full. §3.5.5 pin-only site. Lifted verbatim
  ##     from `unbounded_mupmuc.nim:268-312`.
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
    # sipsic-equiv — lifted from unbounded_sipsic.nim:97-115. No pin
    # required (SPSC has no retire-race). The unified Queue's
    # `tailSegment` is atomic; single-producer means `moRelaxed` load
    # is safe (only this thread writes).
    var seg = self.queue.tailSegment.load(moRelaxed)
    let tail = seg.tail.load(moRelaxed)
    if tail >= S:
      # Allocate new segment. Publish via `seg.next` first (release)
      # so a concurrent consumer that observes the new `next` pointer
      # also sees the segment's initialized fields. Then publish via
      # `tailSegment`.
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
    # sipmuc-equiv — lifted from unbounded_sipmuc.nim:213-229. No pin
    # (single producer; sipmuc's producer-push has no `withPin`).
    # Legacy sipmuc used non-atomic `tailSegment: ptr Segment[...]`;
    # the unified Queue's `tailSegment` is `Atomic[ptr ...]` for
    # field-layout uniformity. Single-producer means `moRelaxed`
    # load + `moRelease` store preserves the legacy ordering (the
    # consumer side reads `headSegment.next`, not `tailSegment`).
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
    # ccProd == ccMulti — both mupsic-equiv (§3.5.4) and mupmuc-equiv
    # (§3.5.5) share the same push body shape; the difference between
    # them is purely on the pop side (consumer cardinality), so the
    # push CAS-loop logic is identical and we share one branch here.
    #
    # §3.5.6 Pin-Claim Ordering: `pinScope` MUST be acquired BEFORE
    # the first `self.queue.tailSegment.load(...)`. Verified by
    # inspection: the `var scope = ...` line is the first statement
    # of this branch; the loop's first action is the segment-pointer
    # load.
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
              # Success edge: loop to retry slot claim on the new
              # segment without backoff (legacy comment lifted from
              # `unbounded_mupsic.nim:273`).
              continue
            else:
              # Lost the segment-alloc race: another producer linked
              # first. Free our orphan and back off before retrying.
              freeAligned(newSeg)
              backoffOnRetry(spins)
              continue
          else:
            # Someone else already linked next; advance tailSegment
            # (best effort, may CAS-fail because someone else
            # advanced) and retry slot claim on the new segment.
            # Success edge, no backoff.
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
        # Lost CAS, retry (no explicit backoff — the CAS itself is
        # the synchronization; legacy mupsic/mupmuc both loop without
        # backoff on slot-CAS failure).
      # scope.=destroy fires here on block exit, driving
      # `PinnedScopeAlive -> PinnedScopeDestroyed` via the registered
      # `{.destructorTransition.}` (typestates 0.9.2 accepts).

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
](self: var Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]) =
  ## Unified `=destroy` hook for `Queue`. Bounded (`RK == rkNone`)
  ## queues require no cleanup — the Vyukov body owns no heap state —
  ## so the destructor is a no-op on that branch and Nim's default
  ## field-wise destruction handles the inline storage and atomic
  ## counters.
  ##
  ## Unbounded (`RK == rkEbr`) queues:
  ##   1. Walk `headSegment` → `next` → ... freeing each segment.
  ##   2. Unbind this queue's client refcount on the manager.
  ##   3. When `ownsManager`, additionally run the manager's destructor
  ##      (drains limbo bags + asserts `clientCount == 0`) and free
  ##      the heap allocation. When `not ownsManager`, leave the
  ##      manager untouched (caller-owned per the borrow overload's
  ##      contract — verified at 3.3.2 commit time via a throwaway
  ##      runtime fixture; the persistent test suite gains a borrow-
  ##      drop fixture in Step 3.3.3/3.3.4 when push/pop bodies land).
  ##
  ## Segment walk shape: in 3.3.2 the constructors do not yet allocate
  ## segments (`Segment` field-set fleshing lands in Step 3.3.3/3.3.4),
  ## so the loop body is unreachable for now — `headSegment` is `nil`
  ## by default and the walk returns immediately. The structural shape
  ## is in place so 3.3.3/3.3.4 only need to wire up `next` plus
  ## per-slot dtor, not re-author the walk.
  ##
  ## The destructor is declared as a single hook covering both `RK`
  ## branches because Nim's destructor binding does not select between
  ## branch-specialized `=destroy` overloads for a generic object; the
  ## `when RK == ...:` dispatch INSIDE the body is the supported shape.
  when RK == rkEbr:
    # Walk the linked-segment list, freeing each segment. Step 3.3.3
    # introduces the `next` field on `Segment[T, ccProd, ccCons, S]`
    # and allocates the initial segment in `newQueue`; the loop is now
    # reachable. Per-slot destructor handling for managed `T` is
    # consolidated into `segmentDestructor` (Step 3.3.4 adds it
    # alongside the pop body's retire path); for the single-threaded
    # `=destroy` path it suffices to walk `next` and `freeAligned`
    # each segment because no other thread can be observing them at
    # destructor time (Nim's destructor semantics + the manager's
    # `clientCount` invariant guarantee no concurrent EBR pin can
    # straddle this point). Managed `T` slots are zero'd via the same
    # `reset` shape the legacy `segmentDestructor` uses (lifted from
    # `unbounded_mupmuc.nim:326` / `unbounded_mupsic.nim:312` /
    # `unbounded_sipmuc.nim:274`); for POD `T`
    # (`supportsCopyMem`) the `reset` loop compile-time-elides.
    var seg = self.headSegment.load(moRelaxed)
    while seg != nil:
      let nextSeg = seg.next.load(moRelaxed)
      when not supportsCopyMem(T):
        for i in 0 ..< S:
          reset(seg.data[i])
      freeAligned(seg)
      seg = nextSeg

    if self.manager != nil:
      unbindClient(self.manager[])
      if self.ownsManager:
        reset(self.manager[])
        freeAligned(self.manager)

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
