## Unbounded multiple-producer, multiple-consumer (MPMC) queue using linked segments.
##
## Uses DEBRA+ epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
## - MaxThreads: Maximum number of threads (compile-time constant).
##
## Both push and pop are lock-free (CAS coordination).
##
## ```nim
## # Auto-create: queue owns a private DebraManager, threads auto-register.
## var queue = newUnboundedMupmuc[64, int, 4]()
## var producer = queue.getProducer()
## var consumer = queue.getConsumer()
## producer.push(42)
## let item = consumer.pop()  # some(42)
## ```
##
## For multi-queue setups that share a manager, pass it explicitly:
##
## ```nim
## var manager = initDebraManager[4]()
## var queue = newUnboundedMupmuc[64, int, 4](addr manager)
## let producerHandle = registerThread(manager)
## let consumerHandle = registerThread(manager)
## var producer = queue.getProducer(producerHandle)
## var consumer = queue.getConsumer(consumerHandle)
## ```
##
## See `unbounded_sipmuc` for documentation of the
## `-d:LockFreeQueuesAdvanceEvery=N` compile-time knob, which also tunes
## this queue's Eager reclamation cadence.
##
## v4.3 facade migration: this module is a thin facade over the typestate
## verbs in ``typestates/unbounded_mpmc_push`` and
## ``typestates/unbounded_mpmc_pop``. Production owns the canonical memory
## layout (Queue and Segment); the typestate Base type's layout equivalence
## is gated by per-field offsetOf / sizeof static-asserts below.

import ./atomic_dsl
import ./backoff
import ./internal/aligned_alloc
import std/options
import std/typetraits

import debra
import typestates
import ./typestates/unbounded_mpmc_push as ts_mpmc_push
import ./typestates/unbounded_mpmc_pop as ts_mpmc_pop

const LockFreeQueuesAdvanceEvery {.intdefine.}: int = 64
  ## Cadence for `advanceEvery` calls in this file's Eager reclamation path.
  ## Override at compile time with `-d:LockFreeQueuesAdvanceEvery=N`.
static:
  assert LockFreeQueuesAdvanceEvery > 0,
    "LockFreeQueuesAdvanceEvery must be a positive integer"

type DeallocationStrategy* = enum
  ## Strategy for segment memory reclamation.
  Manual
    ## Retire segments. User calls tryReclaim().
    ## Best for --mm:none (no GC assistance).
  Eager
    ## Retire + immediate tryReclaim() after each segment retirement.
    ## Best for GC environments.

when defined(gcNone):
  const DefaultDeallocationStrategy* = Manual
else:
  const DefaultDeallocationStrategy* = Eager

type
  Segment[S: static int, T] = object ## A fixed-size segment in the linked list.
    data: array[S, T]
    next {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
    tail {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for producers
    prevConsumerIdx {.align: CacheLineBytes.}: Atomic[int]
      # CAS coordination for consumers
    committed {.align: CacheLineBytes.}: array[S, Atomic[bool]]
      # Track which slots are ready to read

  UnboundedMupmuc*[S: static int, T; MaxThreads: static int] = object
    ## Unbounded MPMC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Consumers read from here
    tailSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Producers write here
    strategy: DeallocationStrategy
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments
    producerCount: Atomic[int]
    consumerCount: Atomic[int]
    ownsManager: bool
      ## True only when the queue allocated its own private manager via
      ## the no-manager-arg constructor; the manager is destroyed and
      ## freed inside `=destroy` after segment cleanup.

  Producer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered producer.
    ##
    ## Producers must call getProducer() before pushing.
    queue: ptr UnboundedMupmuc[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads]

  Consumer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    queue: ptr UnboundedMupmuc[S, T, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads]

# Layout-equivalence gates: production Queue and Segment must have identical
# field offsets (and sizeof) to the typestate Base type/Segment so that the
# `cast[ptr UnboundedMupmucBase[S, T, MaxThreads]](addr self)` in push/pop and
# the typestate's per-Segment-field accesses are sound. See design §2.2 (MPMC
# 9-field set) and §3 Item 2 (MPMC row: both head/tail Segment as
# Atomic[ptr]). 9 Queue offsets + 1 Queue sizeof + 1 Segment sizeof + 5
# Segment offsets + 3 enum asserts = 19 doAsserts.
static:
  # `DeallocationStrategy` enum equivalence: the typestate file declares a
  # local mirror enum (cycle break — see comment at the top of
  # `typestates/unbounded_mpmc_push.nim`). Confirm ord values and storage
  # size match so the `strategy` field's bit-pattern is identical across
  # the two declarations.
  doAssert ord(Manual) == ord(ts_mpmc_push.Manual)
  doAssert ord(Eager) == ord(ts_mpmc_push.Eager)
  doAssert sizeof(DeallocationStrategy) == sizeof(ts_mpmc_push.DeallocationStrategy)
  # Queue-type equivalence (9 fields + sizeof).
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], manager) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], manager)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], headSegment) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], headSegment)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], tailSegment) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], tailSegment)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], strategy) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], strategy)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], itemCount) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], itemCount)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], segments) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], segments)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], producerCount) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], producerCount)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], consumerCount) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], consumerCount)
  doAssert offsetOf(UnboundedMupmuc[64, int, 4], ownsManager) ==
    offsetOf(ts_mpmc_push.UnboundedMupmucBase[64, int, 4], ownsManager)
  doAssert sizeof(UnboundedMupmuc[64, int, 4]) ==
    sizeof(ts_mpmc_push.UnboundedMupmucBase[64, int, 4])
  # Per-Segment-field equivalence (MPMC Segment fields: data, next, tail,
  # prevConsumerIdx, committed).
  doAssert sizeof(Segment[64, int]) == sizeof(ts_mpmc_push.UMPMCSegment[64, int])
  doAssert offsetOf(Segment[64, int], data) ==
    offsetOf(ts_mpmc_push.UMPMCSegment[64, int], data)
  doAssert offsetOf(Segment[64, int], next) ==
    offsetOf(ts_mpmc_push.UMPMCSegment[64, int], next)
  doAssert offsetOf(Segment[64, int], tail) ==
    offsetOf(ts_mpmc_push.UMPMCSegment[64, int], tail)
  doAssert offsetOf(Segment[64, int], prevConsumerIdx) ==
    offsetOf(ts_mpmc_push.UMPMCSegment[64, int], prevConsumerIdx)
  doAssert offsetOf(Segment[64, int], committed) ==
    offsetOf(ts_mpmc_push.UMPMCSegment[64, int], committed)

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## ``{.align.}`` pragmas above land on distinct physical cache lines.
  result = allocAligned[Segment[S, T]]()
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.prevConsumerIdx.store(-1, moRelaxed)
  for i in 0 ..< S:
    result.committed[i].store(false, moRelaxed)

proc newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](
    manager: ptr DebraManager[MaxThreads],
    strategy: DeallocationStrategy = DefaultDeallocationStrategy,
): UnboundedMupmuc[S, T, MaxThreads] =
  ## Create a new unbounded MPMC queue.
  ##
  ## Requires a DebraManager pointer for memory reclamation.
  ## Deallocation strategy defaults based on memory management mode.
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

  result.manager = manager
  result.strategy = strategy
  result.ownsManager = false

  # Refcount this queue against the manager so the manager's `=destroy`
  # asserts cleanly if a shared manager is torn down before its queues.
  bindClient(manager[])

  # Start with one segment
  let seg = newSegment[S, T]()
  result.headSegment.store(seg, moRelaxed)
  result.tailSegment.store(seg, moRelaxed)
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)
  result.producerCount.store(0, moRelaxed)
  result.consumerCount.store(0, moRelaxed)

proc newUnboundedMupmuc*[S: static int, T; MaxThreads: static int](
    strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedMupmuc[S, T, MaxThreads] =
  ## Auto-create overload: heap-allocates a private `DebraManager`
  ## owned by this queue. Manager teardown happens inside this queue's
  ## `=destroy` after segment cleanup. For multi-queue setups that
  ## share a manager, use the `(manager, strategy)` overload instead.
  let mgr = allocAligned[DebraManager[MaxThreads]]()
  var ok = false
  try:
    mgr[] = initDebraManager[MaxThreads]()
    result = newUnboundedMupmuc[S, T, MaxThreads](mgr, strategy)
    result.ownsManager = true
    ok = true
  finally:
    # `finally` (not `except:`) so the cleanup also runs on `Defect`-class
    # raises (e.g. `OutOfMemDefect` from inside `initDebraManager`). Under
    # Nim 2.0, bare `except:` matches only `CatchableError`, leaving
    # Defect-shaped failures to leak `mgr`. Run the manager's `=destroy`
    # (drains any limbo bags + asserts the client refcount is zero) before
    # freeing the heap slot. Safe for both partially- and fully-initialized
    # state because `allocAligned` zeroed it: nil limboBagTail pointers walk
    # no list, boundClients is 0 so the destructor's invariant passes.
    if not ok:
      reset(mgr[])
      freeAligned(mgr)

proc segmentCount*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)

proc len*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)

proc getProducer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Register a new producer and get a handle.
  ##
  ## Returns a Producer handle for pushing items.
  let idx = self.producerCount.fetchAdd(1, moAcquire)
  result.queue = addr self
  result.idx = idx
  result.handle = handle

proc getProducer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): Producer[S, T, MaxThreads] =
  ## Auto-register overload: calls `registerThread(self.manager[])`
  ## internally and returns a Producer. Each call consumes one thread
  ## slot in the manager, and **the slot is not reclaimed when the
  ## Producer is destroyed** — it lives until the manager itself is
  ## destroyed. Calling this in a loop or for short-lived producers
  ## will exhaust `MaxThreads`. Reuse the same Producer per thread,
  ## or use the explicit-handle overload, for long-running managers.
  ## If a thread will use multiple queues sharing a manager, prefer
  ## the explicit-handle overload to avoid burning one slot per queue.
  let handle = registerThread(self.manager[])
  self.getProducer(handle)

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Register a new consumer and get a handle.
  ##
  ## Returns a Consumer handle for popping items.
  let idx = self.consumerCount.fetchAdd(1, moAcquire)
  result.queue = addr self
  result.idx = idx
  result.handle = handle

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Auto-register overload: calls `registerThread(self.manager[])`
  ## internally and returns a Consumer. Each call consumes one thread
  ## slot in the manager, and **the slot is not reclaimed when the
  ## Consumer is destroyed** — it lives until the manager itself is
  ## destroyed. Calling this in a loop or for short-lived consumers
  ## will exhaust `MaxThreads`. Reuse the same Consumer per thread,
  ## or use the explicit-handle overload, for long-running managers.
  ## If a thread will use multiple queues sharing a manager, prefer
  ## the explicit-handle overload to avoid burning one slot per queue.
  let handle = registerThread(self.manager[])
  self.getConsumer(handle)

proc push*[S: static int, T; MaxThreads: static int](
    self: var Producer[S, T, MaxThreads], item: T
) =
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

  # Cast queue to UnboundedMupmucBase for typestate compatibility (sound per
  # the static offsetof asserts at the top of this module). Production
  # Segment and the typestate-local ts_mpmc_push.UMPMCSegment also have
  # identical layouts, so pointer equality and field offsets are
  # interchangeable.
  let queueBase =
    cast[ptr ts_mpmc_push.UnboundedMupmucBase[S, T, MaxThreads]](addr self.queue[])

  # Single `withPin` around the WHOLE verb loop per design §2.3 (NOT
  # one-pin-per-iteration). The actual DEBRA pin is held by `it` (a
  # `RetireReady[MT]` injected by `withPin`); the typestate's
  # `startPush` consumes a `Pinned[MT]`, which we project from `it`
  # (same handle+epoch — the slot's `pinned` flag is unchanged, this is
  # a typestate rebrand symmetric to `pinnedFromRetired`).
  self.handle.withPin:
    while true:
      # Project the active pin (held by `it: RetireReady`) into a Pinned
      # value for the typestate to consume. This is a typestate rebrand
      # (same handle+epoch); the slot's `pinned` flag is unchanged. It
      # mirrors `pinnedFromRetired` from `debra/typestates/retire`.
      let itCtx = RetireContext[MaxThreads](it)
      let pinned = Pinned[MaxThreads](
        EpochGuardContext[MaxThreads](handle: itCtx.handle, epoch: itCtx.epoch)
      )
      var ready = ts_mpmc_push.startPush[T, S, MaxThreads](pinned, queueBase)
      var loaded = ready.loadSegment()
      var claim = loaded.tryClaimSlot()
      match claim:
        UMPMCPushSlotClaimed(slotClaimed):
          discard slotClaimed.writeItem(item).markCommitted()
          break
        UMPMCPushSegmentFull(full):
          # Need a new segment. Allocate first, then link via CAS; if a
          # concurrent producer wins the alloc race, free our orphan and
          # back off (mirrors production at `:294`).
          let newSeg = cast[ptr ts_mpmc_push.UMPMCSegment[S, T]](newSegment[S, T]())
          let (_, allocated) = full.tryAllocateNewSegment(newSeg)
          if not allocated:
            freeAligned(cast[ptr Segment[S, T]](newSeg))
            # CAS-loss-retry on segment-alloc race (producer-vs-producer).
            backoffOnCASLossRetry()
          continue
        UMPMCPushReady(_):
          # Lost slot-claim CAS to a peer producer; loop to retry from
          # Ready. No backoff: the production code does not backoff at
          # this site (production line :308 is a CAS in a tight retry
          # loop without intervening backoff).
          continue

proc push*[S: static int, T; MaxThreads: static int](
    self: var Producer[S, T, MaxThreads], items: openArray[T]
) =
  ## Push multiple items.
  # Bulk variant runs OUTSIDE withPin; each iteration acquires its own pin.
  for item in items:
    self.push(item)

# Typed destructor for retired segments. Must be generic over `(S, T)`
# because the segment's `data: array[S, T]` slots may hold managed types
# (`string`, `seq`, `ref`, ...) whose internal allocations would leak if
# we just `freeAligned`'d the segment block. For POD `T` (`supportsCopyMem`),
# the `reset` loop is compile-time-elided, so this costs nothing.
proc segmentDestructor[S: static int, T](p: pointer) {.nimcall, raises: [].} =
  when not supportsCopyMem(T):
    let seg = cast[ptr Segment[S, T]](p)
    for i in 0 ..< S:
      reset(seg.data[i])
  freeAligned(p)

proc pop*[S: static int, T; MaxThreads: static int](
    self: var Consumer[S, T, MaxThreads]
): Option[T] =
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

  let queueBase =
    cast[ptr ts_mpmc_push.UnboundedMupmucBase[S, T, MaxThreads]](addr self.queue[])

  # Single `withPin` around the WHOLE verb loop per design §2.3 (NOT
  # one-pin-per-iteration). The pin lets us call `it.retire(...)` for
  # retired segments — the facade owns segment lifetime via DEBRA so
  # consumers never observe a freed pointer until every pinned thread
  # has rotated past the retirement epoch.
  self.handle.withPin:
    while true:
      # Project the active pin (held by `it: RetireReady`) into a Pinned
      # value for the typestate to consume. This is a typestate rebrand
      # (same handle+epoch); the slot's `pinned` flag is unchanged. It
      # mirrors `pinnedFromRetired` from `debra/typestates/retire`.
      let itCtx = RetireContext[MaxThreads](it)
      let pinned = Pinned[MaxThreads](
        EpochGuardContext[MaxThreads](handle: itCtx.handle, epoch: itCtx.epoch)
      )
      var ready = ts_mpmc_pop.startPop[T, S, MaxThreads](pinned, queueBase)
      var loaded = ready.loadSegment()
      var claim = loaded.tryClaimSlot()
      match claim:
        UMPMCPopSlotClaimed(slotClaimed):
          # Slot was committed at tryClaimSlot time; readItem performs a
          # paranoid double-check (structurally always succeeds for
          # well-formed producers — see typestate readItem comment).
          var commitCheck = slotClaimed.readItem()
          match commitCheck:
            UMPMCPopComplete(popDone):
              # A3: read the public `value*` field directly. The prior
              # `ts_mpmc_pop.getValue` wrapper added one generic verb-proc
              # instantiation per (T, S, MT, mm-mode) for no behavioral
              # benefit; the field is already public on `UMPMCPopComplete`.
              result = some(popDone.value)
              break
            UMPMCPopSlotUncommitted(_):
              # Defensive arm: producer rolled back committed[]
              # (structurally unreachable). Return none(T) per design §1
              # not-committed semantics — production line :405-406 break.
              break
        UMPMCPopSlotUncommitted(_):
          # Slot reserved but not yet committed (producer still writing).
          # Return none(T) per design §1 — non-blocking pop contract.
          # Mirrors production line :405-407 break.
          break
        UMPMCPopReady(_):
          # Lost prevConsumerIdx CAS to a peer consumer; loop back to
          # re-load and retry. CAS-loss-retry on the consumer-vs-consumer
          # CAS (production line :371 classification per Decision §2.1).
          backoffOnCASLossRetry()
          continue
        UMPMCPopSegmentExhausted(exhausted):
          # Capture the old segment pointer BEFORE the typestate consumes
          # the state — the facade owns segment lifetime and DEBRA-retires
          # the old segment when it wins the headSegment CAS.
          let oldSeg = cast[ptr Segment[S, T]](exhausted.segment)
          var advance = exhausted.advanceSegment()
          match advance:
            UMPMCPopEmpty(_):
              # Transient miss: when oldSeg.next == nil at the load below
              # but the producer publishes immediately after, this pop
              # returns none for one call. The outer pop()/consumer loop
              # re-enters and observes the new state on the next
              # iteration. Working as designed for non-blocking MPMC; not
              # a livelock.
              break
            UMPMCPopReady(_):
              # Item-loss livelock fix (preempted from sipmuc bb50bc9):
              # before CAS-advancing past oldSeg, verify there are no
              # unclaimed items remaining. The producer's invariant is
              # that `oldSeg.next.store(newSeg, moRelease)` happens AFTER
              # `oldSeg.tail` reaches `S` (the segment is full), and
              # producers release-store `committed[slot]` AFTER the CAS
              # on `seg.tail`. The acquire-load on `oldSeg.next`
              # (already performed inside `advanceSegment`) establishes
              # happens-before with the producer's release-store on
              # `next`, so a fresh acquire-load of `prevConsumerIdx`
              # here observes the latest CAS state.
              # If `prevConsumerIdx < S - 1`, items remain unclaimed in
              # `oldSeg`. We MUST NOT advance past it — the items would
              # become unreachable when `oldSeg` is retired and pop
              # would return `none` while items still exist, manifesting
              # as a consumer hot-spin at end-of-run when producers
              # filled the final segment after a consumer's stale tail
              # snapshot.
              #
              # The combined defense — typestate-side `tryClaimSlot`
              # re-loads `seg.tail` before transitioning to Exhausted,
              # plus this facade-side `prevConsumerIdx` re-check before
              # advancing — closes the same TOCTOU window that affected
              # SPMC pop. MPMC has the same SHAPE (snapshot tail +
              # advance segment + CAS-advance head) and is preempted
              # here so Phase C's TSAN×100 doesn't surface the bug a
              # second time.
              let freshPrevIdx = oldSeg.prevConsumerIdx.load(moAcquire)
              if freshPrevIdx < S - 1:
                # Unclaimed slots remain in oldSeg. Skip the head CAS
                # and retire — loop back to re-load and try to claim.
                backoffOnCASLossRetry()
                continue
              # Try to be the thread that retires this segment by CAS-
              # advancing headSegment from oldSeg to the next segment.
              # The winner retires; the loser observes that another
              # consumer already advanced and continues. Mirrors the
              # consumer-vs-consumer coordination the previous direct
              # production code performed at the head-advance site
              # (production line :381-403).
              let nextSeg = cast[ptr Segment[S, T]](oldSeg.next.load(moAcquire))
              var expected = oldSeg
              if self.queue.headSegment.compareExchange(
                expected, nextSeg, moAcquireRelease, moAcquire
              ):
                # Always retire the detached segment so DEBRA owns it: in
                # Manual mode the user (or `manager.=destroy` at scope
                # exit) drains the limbo bag via `tryReclaim`; in Eager
                # mode the per-pop `reclaimNow` call below does it.
                # Without retiring, the segment is detached from the head
                # chain but reachable from no root, and leaks at process
                # exit. Only the live segmentCount is mode-dependent.
                it.retire(cast[pointer](oldSeg), segmentDestructor[S, T])
                if self.queue.strategy != Manual:
                  discard self.queue.segments.fetchSub(1, moRelaxed)
              # CAS-loss-retry on segment-advance (consumer-vs-consumer
              # headSegment CAS — production line :401).
              backoffOnCASLossRetry()
              continue

  if self.queue.strategy == Eager:
    if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
      discard reclaimNow(self.handle)

proc pop*[S: static int, T; MaxThreads: static int](
    self: var Consumer[S, T, MaxThreads], count: int
): Option[seq[T]] =
  ## Pop up to count items.
  ##
  ## Returns some(seq[T]) with at least one item, none if empty.
  if count <= 0:
    return none(seq[T])

  var items = newSeq[T]()

  # Bulk variant runs OUTSIDE withPin; each iteration acquires its own pin
  # via the per-iteration single-item `pop()` call.
  for i in 0 ..< count:
    let item = self.pop()
    if item.isNone:
      break
    items.add(item.get)

  if items.len == 0:
    return none(seq[T])
  return some(items)

when defined(testing):
  proc headSegmentForTest*[S: static int, T; MaxThreads: static int](
      self: var UnboundedMupmuc[S, T, MaxThreads]
  ): pointer =
    ## Test-only accessor: returns the queue's current head segment pointer
    ## so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentHeadOffsetForTest*[S: static int, T; MaxThreads: static int](
      _: typedesc[UnboundedMupmuc[S, T, MaxThreads]]
  ): tuple[tail: int, prevConsumerIdx: int, committed: int] =
    ## Test-only accessor: returns offsets of cache-line-padded fields within
    ## the unbounded mupmuc Segment for the cache-line padding audit.
    result = (
      offsetOf(Segment[S, T], tail),
      offsetOf(Segment[S, T], prevConsumerIdx),
      offsetOf(Segment[S, T], committed),
    )

proc `=destroy`*[S: static int, T; MaxThreads: static int](
    self: var UnboundedMupmuc[S, T, MaxThreads]
) =
  ## Clean up all segments. Releases this queue's client refcount on
  ## the manager; if the queue owns a private manager (auto-create
  ## overload), tears that manager down and frees it.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    let next = seg.next.load(moRelaxed)
    when not supportsCopyMem(T):
      # Run the destructor for any managed slots (string/seq/ref) before
      # `freeAligned`'s away the segment block — otherwise their internal
      # allocations leak.
      for i in 0 ..< S:
        reset(seg.data[i])
    freeAligned(seg)
    seg = next

  # Release our refcount on the manager. Conceptually pairs with the
  # `bindClient` call in the constructor. Done after segment cleanup so
  # we are demonstrably finished using the manager before unbinding.
  if self.manager != nil:
    unbindClient(self.manager[])
    if self.ownsManager:
      # Run the manager's destructor (drains limbo bags, asserts
      # clientCount == 0). `reset` invokes the type's `=destroy` hook
      # without the parsing surprise of the backtick form, which trips
      # `expr(nkIdent); unknown node kind` inside a generic destructor.
      reset(self.manager[])
      freeAligned(self.manager)
