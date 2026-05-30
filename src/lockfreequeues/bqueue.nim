## Bounded lock-free queue — `BQueue[T, ccProd, ccCons, N, P, C]`.
##
## A 6-param bounded ring-buffer surface with no debra integration and
## no `ST`/`S`/`MaxThreads` axes. Cardinality dispatch uses
## `when (ccProd, ccCons) is` internally.
##
## **Param order is LOAD-BEARING**: `T, ccProd, ccCons, N, P, C`.
##
## **No cross-import.** `bqueue.nim` MUST NOT `import ./queue` (or
## vice-versa). Shared helpers route through `./internal/shared`. Any
## helper added to `internal/shared` is available to both modules
## without creating a backward dependency that would defeat the split.
##
## **Field-layout invariant.** Bounded queue bodies preserve the
## offset prefix required by the typestate Base types (`SpscBase`,
## `MpscBase`, `SpmcBase`, `MpmcBase`, `*PushBase`). The
## `static:` offsetOf asserts below lock the prefix at canonical
## instantiations so the unsafe casts in the push/pop bodies remain
## sound. Object-field offsets are computed structurally, so a match
## for one instantiation implies a match for all.
##
## **Cardinality dispatch ladder.** The four (ccProd × ccCons) combos
## are handled by `when` arms inside the procs, matching the layout
## the legacy per-family files (`spsc.nim` / `mpsc.nim` /
## `spmc.nim` / `mpmc.nim`) used pre-unification:
##   - `ccSingle × ccSingle` (SPSC):   direct `Queue.push` / `Queue.pop`.
##   - `ccMulti  × ccSingle` (MPSC):   producer.push / direct pop.
##   - `ccSingle × ccMulti`  (SPMC):   direct push / consumer.pop.
##   - `ccMulti  × ccMulti`  (MPMC):   producer.push / consumer.pop.
##
## Multi-side direct-on-queue calls are gated by compile-time
## `{.error.}` overloads — calling `BQueue.push(item)` on a
## `ccProd == ccMulti` queue (or `BQueue.pop()` on `ccCons == ccMulti`)
## fails at compile time with a message pointing the caller at
## `BQueue.getProducer().push(item)` / `BQueue.getConsumer().pop()`.

# Upstream `typestates` package's `typestate` / `destructorTransition`
# / `transitionError` DSL macros. Pulled in via a shim under
# `./internal/` because a direct `import typestates` from this file
# resolves to the local `./typestates.nim` re-export sibling (which
# does not re-export the upstream macros). See
# `./internal/typestates_dsl.nim` for the resolution-shadowing rationale.
import ./internal/typestates_dsl

import ./internal/pinscope_stub
import ./internal/aligned_alloc
import debra/atomics
import ./backoff
import ./internal/shared
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

export exceptions
export PinScopeCardinality, NoSlice

## ----------------------------------------------------------------------
## Middle-axis Lifecycle typestate.
##
## Tracks `QueueInit -> QueueDestroyed` on the BQueue value itself.
## Mirrors nim-debra's `pinned_scope.nim` (lines 67-93) verbatim in
## structure:
##
## - Phantom context type carries the BQueue's generic params (T,
##   cardinalities, sizes) and `of RootObj` so the state types can
##   `distinct` from it and the typestate's `inheritsFromRootObj = true`
##   flag is honored.
## - Two state types (initial `BQueueInit` + terminal `BQueueDestroyed`)
##   are phantom — they never appear in user code; they exist purely so
##   the typestate verifier can attach them to BQueue and drive the
##   `=destroy` transition.
## - The single transition lives on `=destroy` via `destructorTransition`
##   (line further below in the destructor section). State-preserving
##   ops (`push`, `pop`, `getProducer`, `getConsumer`, `attach`,
##   `detach`, batch variants) declare NO transition pragma — the
##   typestate verifier accepts same-module state-preserving methods on
##   attached types as non-transitioning operations that mutate runtime
##   fields without changing the static typestate.
##
## **State-preserving discipline:** every state-preserving op on BQueue
## stays in bqueue.nim (same module) and omits `{.transition.}`. Cross-
## module callers would need `{.notATransition.}` per
## `pragmas.nim:633-642`; the current implementation does NOT expose
## any cross-module state-preserving ops, so none are tagged.
## ----------------------------------------------------------------------

type
  BQueueLifecycleCtx*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ] = object of RootObj
    ## Phantom context type for the BQueue Lifecycle typestate. Never
    ## instantiated at runtime; carries the generic param shape so the
    ## state types below can `distinct` from it.

  BQueueInit*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ] = distinct BQueueLifecycleCtx[T, ccProd, ccCons, N, P, C]
    ## Initial Lifecycle state for a BQueue. Every newly constructed
    ## BQueue enters this state via the `{.BQueueLifecycle: BQueueInit.}`
    ## attachment pragma on the BQueue object below.

  BQueueDestroyed*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ] = distinct BQueueLifecycleCtx[T, ccProd, ccCons, N, P, C]
    ## Terminal Lifecycle state for a BQueue. Reached exclusively via
    ## the BQueue `=destroy` destructor's `destructorTransition`.

typestate BQueueLifecycle[
    T,
    ccProd: static PinScopeCardinality,
    ccCons: static PinScopeCardinality,
    N: static int,
    P: static int,
    C: static int,
]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  strictTransitions = false
  states:
    BQueueInit[T, ccProd, ccCons, N, P, C]
    BQueueDestroyed[T, ccProd, ccCons, N, P, C]
  initial:
    BQueueInit[T, ccProd, ccCons, N, P, C]
  terminal:
    BQueueDestroyed[T, ccProd, ccCons, N, P, C]
  transitions:
    BQueueInit[T, ccProd, ccCons, N, P, C] ->
      BQueueDestroyed[T, ccProd, ccCons, N, P, C]


type
  BQueue*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ] {.BQueueLifecycle: BQueueInit.} = object
    ## Bounded lock-free queue with cardinality-dispatched Vyukov /
    ## Spsc internals. No debra integration; the bounded body owns no
    ## heap state and the default destructor is sufficient.
    ##
    ## Field-layout split by cardinality matches the unified
    ## `Queue[..., rkNone, ...]` bounded body verbatim (lifted from
    ## `queue.nim` L170-194 at HEAD 2ddca6a, with `ST` and `RK`
    ## phantom-params dropped):
    ##   - SPSC (`ccSingle × ccSingle`): `StorageN1[N, T]` (N+1 slots,
    ##     no per-slot seq counter); head/tail are `Atomic[int]`.
    ##   - All other bounded shapes (MPSC / SPMC / MPMC):
    ##     `MPMCCellArrayN[N, T]` (Vyukov per-slot seq counters);
    ##     head/tail are `Atomic[uint64]`.
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

## ----------------------------------------------------------------------
## Param-coherence guards — bounded subset of 
##
## The 6 rkNone-side guards from the legacy `assertQueueParams`
## (queue.nim L274-297 at HEAD 2ddca6a). The unbounded-side guards
## (`S > 0`, `MaxThreads > 0`, `N == 0 and P == 0 and C == 0`) do not
## apply to BQueue — BQueue has no `S` or `MaxThreads` and its `N` is
## required positive.
## ----------------------------------------------------------------------

template assertBQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
]() =
  static:
    assert N > 0, "BQueue requires N > 0 (bounded slot count)"
  when ccProd == ccMulti:
    static:
      assert P > 0,
        "BQueue[..., ccProd=ccMulti] requires P > 0 " &
          "(per-producer state count)"
  when ccProd == ccSingle:
    static:
      assert P == 0, "BQueue[..., ccProd=ccSingle] must have P == 0"
  when ccCons == ccMulti:
    static:
      assert C > 0,
        "BQueue[..., ccCons=ccMulti] requires C > 0 " &
          "(per-consumer state count)"
  when ccCons == ccSingle:
    static:
      assert C == 0, "BQueue[..., ccCons=ccSingle] must have C == 0"

proc validateBQueueParams*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](_: typedesc[BQueue[T, ccProd, ccCons, N, P, C]]) =
  ## Compile-time entry point for BQueue's 4-5 param-coherence guards
  ## (subset of ). Invoked implicitly by `initBQueue`;
  ## callers may invoke explicitly to exercise the guards in isolation.
  ## Has no runtime cost.
  assertBQueueParams[T, ccProd, ccCons, N, P, C]()
  discard

## ----------------------------------------------------------------------
## Field-offset prefix invariants vs typestate Base types.
##
## The bounded push/pop ladders below cast `BQueue` pointers to the
## per-family typestate Base types (`SpscBase`, `MpscBase`,
## `SpmcBase`, `MpmcBase`, `*PushBase`). For those casts to be
## sound the BQueue object must share its leading field layout with
## each Base. Pin one canonical instantiation per cardinality (per
## legacy `mpsc.nim:60-72` rationale: object-field offsets are
## computed structurally, so a match for one instantiation implies a
## match for all).
## ----------------------------------------------------------------------

static:
  # SPSC (ccSingle × ccSingle) shares head/tail/storage with SpscBase.
  doAssert offsetOf(BQueue[int, ccSingle, ccSingle, 8, 0, 0], head) ==
    offsetOf(SpscBase[8, int], head)
  doAssert offsetOf(BQueue[int, ccSingle, ccSingle, 8, 0, 0], tail) ==
    offsetOf(SpscBase[8, int], tail)
  doAssert offsetOf(BQueue[int, ccSingle, ccSingle, 8, 0, 0], storage) ==
    offsetOf(SpscBase[8, int], storage)

  # MPSC (ccMulti × ccSingle) shares head/tail/cells with
  # MpscPushBase / MpscBase.
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], head) ==
    offsetOf(MpscPushBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], tail) ==
    offsetOf(MpscPushBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], cells) ==
    offsetOf(MpscPushBase[8, 4, int], cells)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], head) ==
    offsetOf(MpscBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], tail) ==
    offsetOf(MpscBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], cells) ==
    offsetOf(MpscBase[8, 4, int], cells)

  # SPMC (ccSingle × ccMulti) shares head/tail/cells with
  # SpmcPushBase / SpmcBase.
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], head) ==
    offsetOf(SpmcPushBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], tail) ==
    offsetOf(SpmcPushBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], cells) ==
    offsetOf(SpmcPushBase[8, 4, int], cells)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], head) ==
    offsetOf(SpmcBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], tail) ==
    offsetOf(SpmcBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], cells) ==
    offsetOf(SpmcBase[8, 4, int], cells)

  # MPMC (ccMulti × ccMulti) shares head/tail/cells with
  # MpmcPushBase / MpmcBase.
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], head) ==
    offsetOf(MpmcPushBase[8, 4, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], tail) ==
    offsetOf(MpmcPushBase[8, 4, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], cells) ==
    offsetOf(MpmcPushBase[8, 4, 4, int], cells)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], head) ==
    offsetOf(MpmcBase[8, 4, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], tail) ==
    offsetOf(MpmcBase[8, 4, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], cells) ==
    offsetOf(MpmcBase[8, 4, 4, int], cells)


## ----------------------------------------------------------------------
## Constructor / accessors — bounded subset.
##
## Lifted from queue.nim L485-545 at HEAD 2ddca6a with the unified type
## signature replaced by BQueue's 6-param form (ST dropped).
## ----------------------------------------------------------------------

proc clear[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccCons, N, P, C]) =
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

proc initBQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](): BQueue[T, ccProd, ccCons, N, P, C] =
  ## Bounded-queue constructor. Initializes the slot storage, zeroes
  ## head/tail, and clears any producer/consumer thread-id registry
  ## tables (multi-cardinality only).
  ##
  ## `initBQueue` is the primitive that returns a freshly cleared
  ## `BQueue` value. `newBQueue` is the canonical smart constructor and
  ## forwards verbatim — callers should prefer `newBQueue`.
  validateBQueueParams(BQueue[T, ccProd, ccCons, N, P, C])
  result.clear()

proc newBQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](): BQueue[T, ccProd, ccCons, N, P, C] {.inline.} =
  ## Canonical bounded-queue smart constructor (M4 alias-return lock —
  ## returns the user-visible `BQueue` alias, never a backing type).
  ##
  ## Forwards to `initBQueue`. The family-named helpers
  ## (`newSpscQueue` / `newMpscQueue` / `newSpmcQueue` /
  ## `newMpmcQueue`) are thin wrappers around this generic ctor with
  ## the cardinality pre-bound; they exist for ergonomic continuity with
  ## the v3.x → v4.x naming and minimize churn in the test suite.
  initBQueue[T, ccProd, ccCons, N, P, C]()

## ----------------------------------------------------------------------
## Family-named bounded smart constructors.
##
## Thin wrappers around `newBQueue` with cardinality pre-bound. M4
## alias-return lock honored — every signature returns the user-visible
## `BQueue` alias, never a backing `*Multi`/`*Single` type. The wrappers
## stay because the test suite (and downstream user code) reach
## `newSpscQueue`/`newMpscQueue`/`newSpmcQueue`/`newMpmcQueue`
## widely; replacing them all with raw `newBQueue[...]` invocations
## would be a large mechanical change with no semantic benefit.
## ----------------------------------------------------------------------

proc newSpscQueue*[T; N: static int](): BQueue[T, ccSingle, ccSingle, N, 0, 0] {.inline.} =
  ## Bounded spsc-equivalent (`ccSingle × ccSingle`) smart-constructor.
  newBQueue[T, ccSingle, ccSingle, N, 0, 0]()

proc newMpscQueue*[T; N, P: static int](): BQueue[T, ccMulti, ccSingle, N, P, 0] {.inline.} =
  ## Bounded mpsc-equivalent (`ccMulti × ccSingle`) smart-constructor.
  ## `P` is the producer-registry capacity.
  newBQueue[T, ccMulti, ccSingle, N, P, 0]()

proc newSpmcQueue*[T; N, C: static int](): BQueue[T, ccSingle, ccMulti, N, 0, C] {.inline.} =
  ## Bounded spmc-equivalent (`ccSingle × ccMulti`) smart-constructor.
  ## `C` is the consumer-registry capacity.
  newBQueue[T, ccSingle, ccMulti, N, 0, C]()

proc newMpmcQueue*[T; N, P, C: static int](): BQueue[T, ccMulti, ccMulti, N, P, C] {.inline.} =
  ## Bounded mpmc-equivalent (`ccMulti × ccMulti`) smart-constructor.
  ## `P` is the producer-registry capacity, `C` is the consumer-registry
  ## capacity.
  newBQueue[T, ccMulti, ccMulti, N, P, C]()

proc capacity*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccCons, N, P, C]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N

proc producerCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccCons, N, P, C]): int {.inline.} =
  ## Returns the queue's producer-registry capacity (`P`).
  ## Single-producer shapes report 0.
  result = P

proc consumerCount*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccCons, N, P, C]): int {.inline.} =
  ## Returns the queue's consumer-registry capacity (`C`).
  ## Single-consumer shapes report 0.
  result = C

## ----------------------------------------------------------------------
## getProducer / getConsumer — multi-cardinality thread-id registration.
##
## Defined only for `ccProd == ccMulti` resp. `ccCons == ccMulti`.
## Single-cardinality side pushes/pops directly through `BQueue.push` /
## `BQueue.pop` (no handshake required). Lifted from queue.nim
## L557-632 with the bounded-only `RK == rkNone` arm extracted.
## ----------------------------------------------------------------------


# --- SPSC push (direct on BQueue) ----------------------------------------
proc push*[T; N: static int](
    self: var BQueue[T, ccSingle, ccSingle, N, 0, 0], item: T
): bool =
  ## SPSC single-item push (lock-free; uses the SPSC typestate verbs).
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "BQueue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  var queueBase = cast[ptr SpscBase[N, T]](addr self)

  let op = spsc_push.start[N]()
  let loaded = op.loadPointers(queueBase[])
  var fullCheck = loaded.checkFull()

  match fullCheck:
    SPSCPushFull(full):
      return full.extractFalse()
    SPSCPushNotFull(notFull):
      return notFull.writeData(queueBase[], item).complete(queueBase[])

# --- SPMC push (direct on BQueue; single producer side) ------------------
proc push*[T; N, C: static int](
    self: var BQueue[T, ccSingle, ccMulti, N, 0, C], item: T
): bool =
  ## SPMC single-item push (defensive CAS, single-producer-side).
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "BQueue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  var queueBase = cast[ptr SpmcPushBase[N, C, T]](addr self)

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

# illegal call at compile time instead of at the first call site.
proc push*[
    T;
    ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccMulti, ccCons, N, P, C], item: T): bool {.error:
    "Direct push on a multi-producer BQueue is not allowed. " &
    "Use BQueue.getProducer().push(item) to obtain a per-thread " &
    "BQueueProducer and push through it.".} =
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "BQueue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}
  discard

# --- SPSC pop (direct on BQueue) -----------------------------------------
proc pop*[T; N: static int](
    self: var BQueue[T, ccSingle, ccSingle, N, 0, 0]
): Option[T] =
  ## SPSC single-item pop.
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "BQueue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  var queueBase = cast[ptr SpscBase[N, T]](addr self)

  let op = spsc_pop.start[N]()
  let loaded = op.loadPointers(queueBase[])
  var emptyCheck = loaded.checkEmpty()

  match emptyCheck:
    SPSCPopEmpty(_):
      return none(T)
    SPSCPopNotEmpty(notEmpty):
      return some(notEmpty.complete(queueBase[]))

# --- MPSC pop (direct on BQueue; single consumer side) -------------------
proc pop*[T; N, P: static int](
    self: var BQueue[T, ccMulti, ccSingle, N, P, 0]
): Option[T] =
  ## MPSC single-item pop (defensive CAS, single-consumer-side).
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "BQueue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}

  var queueBase = cast[ptr MpscBase[N, P, T]](addr self)

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


# alias name `BQueueConsumer`.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccMulti, N, P, C]): Option[T] {.error:
    "Direct pop on a multi-consumer BQueue is not allowed. " &
    "Use BQueue.getConsumer().pop() to obtain a per-thread " &
    "BQueueConsumer and pop through it.".} =
  when not defined(allowNonLockFreeQueueItems):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      when T is ref:
        {.
          error:
            "BQueue item type '" & $T & "' is a ref type. " &
            "Slots are stored in a shared array; `=copy`/`=sink` hooks " &
            "mutate the refcount on the same object multiple threads can " &
            "read or write, which is a race regardless of whether the " &
            "refcount itself is atomic. Use a lock-free type (int, " &
            "pointer, ptr T, etc.) or compile with " &
            "-d:allowNonLockFreeQueueItems to explicitly allow it."
        .}
  discard

## ----------------------------------------------------------------------
## Batch push / pop — `openArray` and `count`-style overloads.
##
## Batch operations are best-effort loops over single-item primitives
## (semantic carried from the legacy bodies; batch atomicity is
## intentionally NOT preserved).
## ----------------------------------------------------------------------

# --- SPSC batch push (direct on BQueue) ----------------------------------
proc push*[T; N: static int](
    self: var BQueue[T, ccSingle, ccSingle, N, 0, 0],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## SPSC batch push.
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

# --- SPMC batch push (direct on BQueue) ----------------------------------
proc push*[T; N, C: static int](
    self: var BQueue[T, ccSingle, ccMulti, N, 0, C],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## SPMC batch push (loop of single-item pushes).
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

# alias name `BQueueProducer`.
proc push*[
    T;
    ccCons: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccMulti, ccCons, N, P, C], items: openArray[T]
): Option[HSlice[int, int]] {.error:
    "Direct batch push on a multi-producer BQueue is not allowed. " &
    "Use BQueue.getProducer().push(items) to obtain a per-thread " &
    "BQueueProducer and batch-push through it.".} =
  discard

# --- SPSC batch pop (direct on BQueue) -----------------------------------
proc pop*[T; N: static int](
    self: var BQueue[T, ccSingle, ccSingle, N, 0, 0], count: int
): Option[seq[T]] =
  ## SPSC batch pop.
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

# --- MPSC batch pop (direct on BQueue) -----------------------------------
proc pop*[T; N, P: static int](
    self: var BQueue[T, ccMulti, ccSingle, N, P, 0], count: int
): Option[seq[T]] =
  ## MPSC batch pop (loop of single-item pops).
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


# alias name `BQueueConsumer`.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccProd, ccMulti, N, P, C], count: int
): Option[seq[T]] {.error:
    "Direct batch pop on a multi-consumer BQueue is not allowed. " &
    "Use BQueue.getConsumer().pop(count) to obtain a per-thread " &
    "BQueueConsumer and batch-pop through it.".} =
  discard


## ----------------------------------------------------------------------
## Destructors driving Lifecycle / Claim-state terminal transitions
##.
##
## Mirror nim-debra `pinned_scope.nim:178-180` verbatim: the typestate
## terminal transition is emitted by `=destroy` via
## `destructorTransition: InitialState -> TerminalState`. State-
## preserving ops (push, pop, getProducer, getConsumer, attach,
## detach) declare no transition pragma; the typestate stays
## static-stable across them and only the destructor moves the value
## to the terminal state.
##
## **transitionError apparatus reinterpretation**: the master brief
##  calls for "sibling-pragma transitionError at every
## push/pop/etc. site." Per the B.4.1.5 probe, push/pop are NOT
## transitions (they declare no `{.transition.}`); `transitionError`
## attaches only to transition declarations. The destructor IS a
## transition, so its `transitionError` carries the user-visible
## diagnostic. push/pop have no `transitionError` annotation because
## they have nothing to attach it to.
##
## **Limitation**: typestates v0.9.3 does NOT statically catch a
## use-after-destroy (a method call on a value already in
## BQueueDestroyed). The CFG analyzer enforces "reaches terminal by
## end of scope," not "no method calls on a value already in terminal
## state." Documented in CHANGELOG v5.0.0.
## ----------------------------------------------------------------------

proc `=destroy`*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccCons, N, P, C]) {.
    destructorTransition: BQueueInit -> BQueueDestroyed,
    transitionError:
      "BQueue used after =destroy (lifecycle: BQueueInit -> BQueueDestroyed).",
    raises: [],
.} =
  ## BQueue destructor — drives the Lifecycle terminal transition.
  ##
  ## BQueue owns no heap state (no debra integration, no segment list,
  ## no manager pointer); the default destructor would suffice for
  ## memory hygiene. The destructor body is empty, and its sole
  ## purpose is to emit the `BQueueInit -> BQueueDestroyed` transition
  ## for the Lifecycle typestate via the `destructorTransition`
  ## pragma.
  discard


## ----------------------------------------------------------------------
## Test-only introspection helpers.
##
## Mirrors the bounded subset of queue.nim's `when defined(testing):`
## block. The unbounded-only helpers (Segment introspection) stay in
## queue.nim.
## ----------------------------------------------------------------------

when defined(testing):
  from unittest import check

  proc reset*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ](self: var BQueue[T, ccProd, ccCons, N, P, C]) =
    ## Resets the queue to its default state. For single-threaded unit
    ## tests only.
    self.clear()

  proc checkState*[T; N: static int](
      self: var BQueue[T, ccSingle, ccSingle, N, 0, 0],
      head: int,
      tail: int,
      storage: seq[T],
  ) =
    ## SPSC `checkState`.
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 .. N:
      if i < storage.len:
        check(self.storage.data[i] == storage[i])

  proc checkState*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ](
      self: var BQueue[T, ccProd, ccCons, N, P, C],
      head: uint64,
      tail: uint64,
  ) =
    ## Non-SPSC head+tail-only `checkState`.
    when ccProd == ccSingle and ccCons == ccSingle:
      {.
        error:
          "checkState(uint64) not applicable to SPSC; use the int " &
          "+ seq[T] overload"
      .}
    else:
      check(self.head.load(moRelaxed) == head)
      check(self.tail.load(moRelaxed) == tail)

  proc checkState*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ](
      self: var BQueue[T, ccProd, ccCons, N, P, C],
      head: uint64,
      tail: uint64,
      data: seq[T],
  ) =
    ## Non-SPSC head+tail+data `checkState`.
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
