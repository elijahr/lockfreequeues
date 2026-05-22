## Bounded lock-free queue — `BQueue[T, ccProd, ccCons, N, P, C]`.
##
## Step 3.3.11-B (sub-dispatch B.1) extracts the bounded-only surface
## of the legacy unified `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S,
## MaxThreads]` (10 params) into a fresh 6-param type that has no
## debra integration, no `ST`/`RK`/`S`/`MaxThreads` axes, and uses
## cardinality-only `when (ccProd, ccCons) is` dispatch internally
## rather than the legacy `when RK == rkNone:` arm.
##
## **Param order is LOAD-BEARING**: `T, ccProd, ccCons, N, P, C`.
##
## **Sub-dispatch boundary.** This file is created in 3.3.11-B.1 while
## `queue.nim` continues to host the unified `Queue` (including its
## own bounded surface). The two modules coexist post-B.1: BQueue is
## an additional, parallel API. Sub-dispatch B.2 (Bundle C) strips the
## bounded arm from `queue.nim`, after which BQueue is the sole owner
## of the bounded shape and `queue.nim` carries only the unbounded
## (debra-integrated) body plus the absorbed UnboundedSipsic branch.
##
## **No cross-import.** Per pepper M2, `bqueue.nim` MUST NOT
## `import ./queue` (or vice-versa). Shared helpers route through
## `./internal/shared`. Any helper added to `internal/shared` is
## available to both modules without creating a backward dependency
## that would defeat the split.
##
## **Field-layout invariant.** Bounded queue bodies preserve the
## offset prefix required by the typestate Base types (`SipsicBase`,
## `MupsicBase`, `SipmucBase`, `MupmucBase`, `*PushBase`). The
## `static:` offsetOf asserts below lock the prefix at canonical
## instantiations so the unsafe casts in the push/pop bodies remain
## sound. Object-field offsets are computed structurally, so a match
## for one instantiation implies a match for all (per legacy
## `mupsic.nim` lines 60-72 rationale).
##
## **Cardinality dispatch ladder.** The four (ccProd × ccCons) combos
## are handled by `when` arms inside the procs, matching the layout
## the legacy per-family files (`sipsic.nim` / `mupsic.nim` /
## `sipmuc.nim` / `mupmuc.nim`) used pre-unification:
##   - `ccSingle × ccSingle` (SPSC):   direct `Queue.push` / `Queue.pop`.
##   - `ccMulti  × ccSingle` (MPSC):   producer.push / direct pop.
##   - `ccSingle × ccMulti`  (SPMC):   direct push / consumer.pop.
##   - `ccMulti  × ccMulti`  (MPMC):   producer.push / consumer.pop.
##
## Multi-side direct-on-queue calls land on the `InvalidCallDefect`
## traps below; Bundle E (sub-dispatch B.2) replaces those traps with
## compile-time `{.error.}` overloads.

import ./internal/pinscope_stub
import ./internal/aligned_alloc
import ./atomic_dsl
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

type
  BQueue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
  ] = object
    ## Bounded lock-free queue with cardinality-dispatched Vyukov /
    ## Sipsic internals. No debra integration; the bounded body owns no
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
## Param-coherence guards — bounded subset of Doc C §3.0.2.4.
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
  ## (subset of Doc C §3.0.2.4). Invoked implicitly by `initBQueue`;
  ## callers may invoke explicitly to exercise the guards in isolation.
  ## Has no runtime cost.
  assertBQueueParams[T, ccProd, ccCons, N, P, C]()
  discard

## ----------------------------------------------------------------------
## Field-offset prefix invariants vs typestate Base types.
##
## The bounded push/pop ladders below cast `BQueue` pointers to the
## per-family typestate Base types (`SipsicBase`, `MupsicBase`,
## `SipmucBase`, `MupmucBase`, `*PushBase`). For those casts to be
## sound the BQueue object must share its leading field layout with
## each Base. Pin one canonical instantiation per cardinality (per
## legacy `mupsic.nim:60-72` rationale: object-field offsets are
## computed structurally, so a match for one instantiation implies a
## match for all).
## ----------------------------------------------------------------------

static:
  # SPSC (ccSingle × ccSingle) shares head/tail/storage with SipsicBase.
  doAssert offsetOf(BQueue[int, ccSingle, ccSingle, 8, 0, 0], head) ==
    offsetOf(SipsicBase[8, int], head)
  doAssert offsetOf(BQueue[int, ccSingle, ccSingle, 8, 0, 0], tail) ==
    offsetOf(SipsicBase[8, int], tail)
  doAssert offsetOf(BQueue[int, ccSingle, ccSingle, 8, 0, 0], storage) ==
    offsetOf(SipsicBase[8, int], storage)

  # MPSC (ccMulti × ccSingle) shares head/tail/cells with
  # MupsicPushBase / MupsicBase.
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], head) ==
    offsetOf(MupsicPushBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], tail) ==
    offsetOf(MupsicPushBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], cells) ==
    offsetOf(MupsicPushBase[8, 4, int], cells)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], head) ==
    offsetOf(MupsicBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], tail) ==
    offsetOf(MupsicBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccSingle, 8, 4, 0], cells) ==
    offsetOf(MupsicBase[8, 4, int], cells)

  # SPMC (ccSingle × ccMulti) shares head/tail/cells with
  # SipmucPushBase / SipmucBase.
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], head) ==
    offsetOf(SipmucPushBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], tail) ==
    offsetOf(SipmucPushBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], cells) ==
    offsetOf(SipmucPushBase[8, 4, int], cells)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], head) ==
    offsetOf(SipmucBase[8, 4, int], head)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], tail) ==
    offsetOf(SipmucBase[8, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccSingle, ccMulti, 8, 0, 4], cells) ==
    offsetOf(SipmucBase[8, 4, int], cells)

  # MPMC (ccMulti × ccMulti) shares head/tail/cells with
  # MupmucPushBase / MupmucBase.
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], head) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], tail) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], cells) ==
    offsetOf(MupmucPushBase[8, 4, 4, int], cells)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], head) ==
    offsetOf(MupmucBase[8, 4, 4, int], head)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], tail) ==
    offsetOf(MupmucBase[8, 4, 4, int], tail)
  doAssert offsetOf(BQueue[int, ccMulti, ccMulti, 8, 4, 4], cells) ==
    offsetOf(MupmucBase[8, 4, 4, int], cells)

## ----------------------------------------------------------------------
## View types — distinct from QueueProducer / QueueConsumer.
##
## Per the Bundle B §4 design note (confirmed-acceptable per design),
## views are not shared between BQueue and Queue post-refactor — they
## each get their own view type. View types only carry meaningful
## state on the multi-cardinality side; the single-cardinality variant
## exists for type uniformity (a `BQueueProducer` for `ccProd==ccSingle`
## is never instantiated through the public API — direct
## `BQueue.push` is the canonical path).
## ----------------------------------------------------------------------

type
  BQueueProducer*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ] = object
    ## Per-thread producer handle for a `BQueue`. Retrieved via
    ## `BQueue.getProducer()` when `ccProd == ccMulti`. Defined for
    ## every (ccProd, ccCons) shape for type uniformity.
    idx*: int
    queue*: ptr BQueue[T, ccProd, ccCons, N, P, C]

  BQueueConsumer*[
      T;
      ccProd, ccCons: static PinScopeCardinality,
      N, P, C: static int,
  ] = object
    ## Per-thread consumer handle for a `BQueue`. Retrieved via
    ## `BQueue.getConsumer()` when `ccCons == ccMulti`. Defined for
    ## every (ccProd, ccCons) shape for type uniformity.
    idx*: int
    queue*: ptr BQueue[T, ccProd, ccCons, N, P, C]

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
  ## `initBQueue` parallels the legacy `initQueue` (queue.nim L506) for
  ## the bounded shape. The B.2 sub-dispatch's Bundle D introduces a
  ## smart `newBQueue` constructor on top of this primitive.
  validateBQueueParams(BQueue[T, ccProd, ccCons, N, P, C])
  result.clear()

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

proc getProducer*[
    T;
    ccCons: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccMulti, ccCons, N, P, C], idx: int = -1
): BQueueProducer[T, ccMulti, ccCons, N, P, C] {.
    raises: [NoProducersAvailableError]
.} =
  ## Assigns and returns a `BQueueProducer` for the current thread.
  ## When `idx >= 0`, the caller pins a specific producer slot
  ## (testing). When `idx == -1`, the thread's `getThreadId()` is
  ## stored into the first free slot via a CAS over `producerThreadIds`.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  let threadId = getThreadId()

  for i in 0 ..< P:
    if self.producerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

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
    N, P, C: static int,
](
    self: var BQueue[T, ccProd, ccMulti, N, P, C], idx: int = -1
): BQueueConsumer[T, ccProd, ccMulti, N, P, C] {.
    raises: [NoConsumersAvailableError]
.} =
  ## Assigns and returns a `BQueueConsumer` for the current thread.
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
##   - SPSC: BQueue.push(item)        -> spsc_push
##   - MPSC: producer.push(item)      -> mpsc_push
##   - SPMC: BQueue.push(item)        -> spmc_push
##   - MPMC: producer.push(item)      -> mpmc_push
##
## Single-item pop:
##   - SPSC: BQueue.pop()             -> spsc_pop
##   - MPSC: BQueue.pop()             -> mpsc_pop
##   - SPMC: consumer.pop()           -> spmc_pop
##   - MPMC: consumer.pop()           -> mpmc_pop
##
## Each path is byte-for-byte identical with the legacy bodies in
## queue.nim L654-1032 — only the receiver type differs (BQueue vs the
## unified Queue's rkNone arm).
## ----------------------------------------------------------------------

# --- SPSC push (direct on BQueue) ----------------------------------------
proc push*[T; N: static int](
    self: var BQueue[T, ccSingle, ccSingle, N, 0, 0], item: T
): bool =
  ## SPSC single-item push (lock-free; uses the SPSC typestate verbs).
  var queueBase = cast[ptr SipsicBase[N, T]](addr self)

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

# --- MPSC push (via BQueueProducer) --------------------------------------
proc push*[T; N, P: static int](
    self: BQueueProducer[T, ccMulti, ccSingle, N, P, 0], item: T
): bool =
  ## MPSC single-item push (lock-free; uses the MPSC typestate verbs).
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

# --- MPMC push (via BQueueProducer) --------------------------------------
proc push*[T; N, P, C: static int](
    self: BQueueProducer[T, ccMulti, ccMulti, N, P, C], item: T
): bool =
  ## MPMC single-item push (lock-free; uses the MPMC typestate verbs).
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

# --- ccMulti-producer trap on bare BQueue.push ---------------------------
# Bundle E (sub-dispatch B.2) replaces this runtime raise with a
# compile-time `{.error.}` overload. The traps are kept in B.1 so the
# behavioral contract is byte-identical with the legacy Queue.push trap
# at queue.nim:741 — tests asserting the trap still pass against BQueue.
proc push*[
    T;
    ccCons: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccMulti, ccCons, N, P, C], item: T): bool =
  ## Raises `InvalidCallDefect`. Use `BQueueProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use BQueueProducer.push()")

# --- SPSC pop (direct on BQueue) -----------------------------------------
proc pop*[T; N: static int](
    self: var BQueue[T, ccSingle, ccSingle, N, 0, 0]
): Option[T] =
  ## SPSC single-item pop.
  var queueBase = cast[ptr SipsicBase[N, T]](addr self)

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

# --- SPMC pop (via BQueueConsumer) ---------------------------------------
proc pop*[T; N, C: static int](
    self: BQueueConsumer[T, ccSingle, ccMulti, N, 0, C]
): Option[T] =
  ## SPMC single-item pop.
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

# --- MPMC pop (via BQueueConsumer) ---------------------------------------
proc pop*[T; N, P, C: static int](
    self: BQueueConsumer[T, ccMulti, ccMulti, N, P, C]
): Option[T] =
  ## MPMC single-item pop.
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

# --- ccMulti-consumer trap on bare BQueue.pop ----------------------------
# Bundle E replaces with `{.error.}` overload.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    N, P, C: static int,
](self: var BQueue[T, ccProd, ccMulti, N, P, C]): Option[T] =
  ## Raises `InvalidCallDefect`. Use `BQueueConsumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use BQueueConsumer.pop()")

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

# --- MPSC batch push (via BQueueProducer) --------------------------------
proc push*[T; N, P: static int](
    self: BQueueProducer[T, ccMulti, ccSingle, N, P, 0],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## MPSC batch push (loop of single-item pushes).
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

# --- MPMC batch push (via BQueueProducer) --------------------------------
proc push*[T; N, P, C: static int](
    self: BQueueProducer[T, ccMulti, ccMulti, N, P, C],
    items: openArray[T],
): Option[HSlice[int, int]] =
  ## MPMC batch push (loop of single-item pushes).
  if unlikely(items.len == 0):
    return NoSlice
  for i in 0 ..< items.len:
    if not self.push(items[i]):
      return some(i .. items.len - 1)
  NoSlice

# --- ccMulti-producer trap on bare BQueue.push openArray -----------------
# Bundle E replaces with `{.error.}` overload.
proc push*[
    T;
    ccCons: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccMulti, ccCons, N, P, C], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Raises `InvalidCallDefect`. Use `BQueueProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use BQueueProducer.push()")

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

# --- SPMC batch pop (via BQueueConsumer) ---------------------------------
proc pop*[T; N, C: static int](
    self: BQueueConsumer[T, ccSingle, ccMulti, N, 0, C], count: int
): Option[seq[T]] =
  ## SPMC batch pop (loop of single-item pops).
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

# --- MPMC batch pop (via BQueueConsumer) ---------------------------------
proc pop*[T; N, P, C: static int](
    self: BQueueConsumer[T, ccMulti, ccMulti, N, P, C], count: int
): Option[seq[T]] =
  ## MPMC batch pop (loop of single-item pops).
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

# --- ccMulti-consumer trap on bare BQueue.pop count ----------------------
# Bundle E replaces with `{.error.}` overload.
proc pop*[
    T;
    ccProd: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccProd, ccMulti, N, P, C], count: int
): Option[seq[T]] =
  ## Raises `InvalidCallDefect`. Use `BQueueConsumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use BQueueConsumer.pop()")

## ----------------------------------------------------------------------
## Test-only introspection helpers.
##
## Mirrors the bounded subset of queue.nim L2385+ (`when defined(testing):`
## block). The unbounded-only helpers (Segment introspection) stay in
## queue.nim until Bundle C strips the bounded arm.
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
