## Unbounded single-producer, multiple-consumer (SPMC) queue using linked segments.
##
## Uses DEBRA+ epoch-based reclamation for safe memory deallocation.
##
## - S: Segment size (items per segment). Larger = less allocation, smaller = faster reclamation.
## - T: Type of data the queue holds.
## - MaxThreads: Maximum number of threads (compile-time constant).
##
## Push is wait-free for the single producer.
## Pop is lock-free for multiple consumers (CAS coordination).
##
## ```nim
## # Auto-create: queue owns a private DebraManager, consumers auto-register.
## var queue = newUnboundedSipmuc[64, int, 4]()
## var consumer = queue.getConsumer()
##
## queue.push(42)
## let item = consumer.pop()  # some(42)
## ```
##
## For multi-queue setups that share a manager, pass it explicitly:
##
## ```nim
## var manager = initDebraManager[4]()
## var queue = newUnboundedSipmuc[64, int, 4](addr manager)
## let handle = registerThread(manager)
## var consumer = queue.getConsumer(handle)
## ```
##
## **Compile-time knobs**
##
## - `-d:LockFreeQueuesAdvanceEvery=N` (default 64): cadence at which the
##   unbounded queues' Eager reclamation paths call `advanceEvery` on their
##   DEBRA handle. Lower values advance the global epoch more aggressively
##   (more reclamation work per pop), higher values amortize epoch advancement
##   across more pops at the cost of delaying reclamation. Must be a positive
##   integer.
##
## v4.3 facade migration: this module is a thin facade over the typestate
## verbs in ``typestates/unbounded_spmc_push`` and
## ``typestates/unbounded_spmc_pop``. Production owns the canonical memory
## layout (Queue and Segment); the typestate Base type's layout equivalence
## is gated by per-field offsetOf / sizeof static-asserts below.

import ./atomic_dsl
import ./backoff
import ./internal/aligned_alloc
import std/options
import std/typetraits

import debra
import typestates
import ./typestates/unbounded_spmc_push as ts_spmc_push
import ./typestates/unbounded_spmc_pop as ts_spmc_pop

when defined(awaitingTailTestHook):
  # Test-only: gated synchronization channels for the awaitingTail-strand
  # regression test. See `private/awaiting_tail_test_hook.nim` for the
  # purity contract. DO NOT enable in production builds.
  import private/awaiting_tail_test_hook

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
      # Producer write position within segment
    consumerHead {.align: CacheLineBytes.}: Atomic[int]
      # Next-claimable index — wait-free fetchAdd coordination for consumers
    cellState {.align: CacheLineBytes.}: array[S, Atomic[uint8]]
      # LCRQ per-slot tri-state (CellEmpty/CellFilled/CellClosed); Task 11 C1.
    closed {.align: CacheLineBytes.}: Atomic[bool]
      # Segment-level closed flag (LCRQ adaptation); Task 11 C1.

  UnboundedSipmuc*[S: static int, T; MaxThreads: static int] = object
    ## Unbounded SPMC queue using linked segments.
    ##
    ## - S: Segment size (compile-time constant).
    ## - T: Data type.
    ## - MaxThreads: Maximum number of threads (compile-time constant).
    manager: ptr DebraManager[MaxThreads]
    headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      # Consumers read from here (atomic for CAS-advance coordination)
    tailSegment {.align: CacheLineBytes.}: ptr Segment[S, T]
      # Producer writes here (single-producer, plain ptr; align pragma keeps
      # it on its own cache line so the producer's writes don't bounce the
      # consumer-mutated headSegment line)
    strategy: DeallocationStrategy
    itemCount: Atomic[int] # Total items in queue
    segments: Atomic[int] # Number of segments
    # Consumer tracking
    consumerCount: Atomic[int]
    ownsManager: bool
      ## True only when the queue allocated its own private manager via
      ## the no-manager-arg constructor; the manager is destroyed and
      ## freed inside `=destroy` after segment cleanup.

  Consumer*[S: static int, T; MaxThreads: static int] = object
    ## Handle for a registered consumer.
    ##
    ## Consumers must call getConsumer() before popping.
    ## The consumer is automatically deregistered on destruction.
    queue: ptr UnboundedSipmuc[S, T, MaxThreads]
    idx*: int
    localHead: int # Local tracking of position
    handle: ThreadHandle[MaxThreads] # Thread handle for pin/unpin

# Layout-equivalence gates: production Queue and Segment must have identical
# field offsets (and sizeof) to the typestate Base type/Segment so that the
# `cast[ptr UnboundedSipmucBase[S, T, MaxThreads]](addr self)` in push/pop and
# the typestate's per-Segment-field accesses are sound. See design §2.2 (SPMC
# 8-field set post-Item-5) and §3 Item 2 (SPMC row: headSegment Atomic[ptr],
# tailSegment plain ptr). 8 Queue offsets + 1 Queue sizeof + 1 Segment sizeof
# + 4 Segment offsets = 14 doAsserts.
static:
  # `DeallocationStrategy` enum equivalence: the typestate file declares a
  # local mirror enum (cycle break — see comment at the top of
  # `typestates/unbounded_spmc_push.nim`). Confirm ord values and storage
  # size match so the `strategy` field's bit-pattern is identical across
  # the two declarations.
  doAssert ord(Manual) == ord(ts_spmc_push.Manual)
  doAssert ord(Eager) == ord(ts_spmc_push.Eager)
  doAssert sizeof(DeallocationStrategy) == sizeof(ts_spmc_push.DeallocationStrategy)
  # Queue-type equivalence (8 fields + sizeof).
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], manager) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], manager)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], headSegment) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], headSegment)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], tailSegment) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], tailSegment)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], strategy) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], strategy)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], itemCount) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], itemCount)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], segments) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], segments)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], consumerCount) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], consumerCount)
  doAssert offsetOf(UnboundedSipmuc[64, int, 4], ownsManager) ==
    offsetOf(ts_spmc_push.UnboundedSipmucBase[64, int, 4], ownsManager)
  doAssert sizeof(UnboundedSipmuc[64, int, 4]) ==
    sizeof(ts_spmc_push.UnboundedSipmucBase[64, int, 4])
  # Per-Segment-field equivalence (SPMC Segment fields: data, next, tail,
  # consumerHead).
  doAssert sizeof(Segment[64, int]) == sizeof(ts_spmc_push.Segment[64, int])
  doAssert offsetOf(Segment[64, int], data) ==
    offsetOf(ts_spmc_push.Segment[64, int], data)
  doAssert offsetOf(Segment[64, int], next) ==
    offsetOf(ts_spmc_push.Segment[64, int], next)
  doAssert offsetOf(Segment[64, int], tail) ==
    offsetOf(ts_spmc_push.Segment[64, int], tail)
  doAssert offsetOf(Segment[64, int], consumerHead) ==
    offsetOf(ts_spmc_push.Segment[64, int], consumerHead)

proc newSegment[S: static int, T](): ptr Segment[S, T] =
  ## Allocate a new segment on a CacheLineBytes boundary so the
  ## ``{.align.}`` pragmas above land on distinct physical cache lines.
  result = allocAligned[Segment[S, T]]()
  result.next.store(nil, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.consumerHead.store(0, moRelaxed) # Next-claimable index: 0

proc newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](
    manager: ptr DebraManager[MaxThreads],
    strategy: DeallocationStrategy = DefaultDeallocationStrategy,
): UnboundedSipmuc[S, T, MaxThreads] =
  ## Create a new unbounded SPMC queue.
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
  result.tailSegment = seg
  result.itemCount.store(0, moRelaxed)
  result.segments.store(1, moRelaxed)

  # Initialize consumer tracking
  result.consumerCount.store(0, moRelaxed)

proc newUnboundedSipmuc*[S: static int, T; MaxThreads: static int](
    strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedSipmuc[S, T, MaxThreads] =
  ## Auto-create overload: heap-allocates a private `DebraManager`
  ## owned by this queue. Manager teardown happens inside this queue's
  ## `=destroy` after segment cleanup. For multi-queue setups that
  ## share a manager, use the `(manager, strategy)` overload instead.
  let mgr = allocAligned[DebraManager[MaxThreads]]()
  var ok = false
  try:
    mgr[] = initDebraManager[MaxThreads]()
    result = newUnboundedSipmuc[S, T, MaxThreads](mgr, strategy)
    result.ownsManager = true
    ok = true
  finally:
    # `finally` (not `except:`) so the cleanup also runs on `Defect`-class
    # raises (e.g. `OutOfMemDefect` from inside `initDebraManager`). Under
    # Nim 2.0, bare `except:` matches only `CatchableError`, leaving
    # Defect-shaped failures to leak `mgr`. Run the manager's `=destroy`
    # (drains any limbo bags + asserts the client refcount is zero) before
    # freeing the heap slot. Safe for both partially- and fully-initialized
    # state because `allocAligned` zeroed it.
    if not ok:
      reset(mgr[])
      freeAligned(mgr)

proc segmentCount*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
): int =
  ## Number of segments currently allocated.
  result = self.segments.load(moRelaxed)

proc len*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
): int =
  ## Number of items currently in the queue.
  result = self.itemCount.load(moRelaxed)

proc push*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads], item: sink T
) =
  ## Push a single item. Never blocks or fails (unbounded).
  ##
  ## Single-producer: no `withPin:` scope is needed on the push path
  ## (per design §2.4: the producer doesn't reclaim segments and isn't
  ## racing other producers). Direct match-driven verb pipeline.

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

  # Cast queue to UnboundedSipmucBase for typestate compatibility (sound per
  # the static offsetof asserts at the top of this module). Production
  # Segment and the typestate-local ts_spmc_push.Segment also have identical
  # layouts, so pointer equality and field offsets are interchangeable.
  let queueBase =
    cast[ptr ts_spmc_push.UnboundedSipmucBase[S, T, MaxThreads]](addr self)

  # The push typestate's `startPush` consumes a `Pinned[MT]` for symmetry
  # with the pop side. SPMC has a single producer so the pin is functionally
  # a no-op (no concurrent retires can drop our segment); we synthesise an
  # un-pinned `Pinned[MT]` value with epoch 0 just to satisfy the typestate
  # signature. This avoids requiring a real DEBRA registration on the
  # producer thread (callers may not have one).
  #
  # Granular pipeline (Task 11 LCRQ shape):
  #   startPush(pinned, queueBase, move item)  # item threaded as pendingItem
  #     -> loadSegment -> checkFull
  #        -> SegmentFull -> allocateNewSegment -> Ready (continue)
  #        -> SlotReady   -> writeItem -> USPMCPushCommitResult variant
  #             | Complete         : push done, return
  #             | SegmentLoaded    : reserved-future arm; rebuild Ready and
  #                                  re-loop (writeItem body does not emit
  #                                  this today, see typestate §305-388;
  #                                  arm is required for match exhaustiveness).
  #             | SegmentClosed    : starvation/saturation escalation;
  #                                  closeSegmentDone -> SegmentFull ->
  #                                  allocateNewSegment -> Ready (continue).
  #
  # Synthesised un-pinned `Pinned[MT]`: handle 0, epoch 0. The push verbs
  # treat the pin as opaque payload — they neither pin nor unpin anything
  # because SPMC has no producer-side reclamation. Synthesised once; rebuilt
  # from typestate fields on every loop iteration via `startPush`.
  let pinned = Pinned[MaxThreads](
    EpochGuardContext[MaxThreads](handle: ThreadHandle[MaxThreads](), epoch: 0)
  )
  var ready =
    ts_spmc_push.startPush[T, S, MaxThreads](pinned, queueBase, move item)
  while true:
    let loaded = ready.loadSegment()
    var check = loaded.checkFull()
    match check:
      USPMCPushSegmentFull(full):
        let newSeg = cast[ptr ts_spmc_push.Segment[S, T]](newSegment[S, T]())
        ready = full.allocateNewSegment(newSeg)
        continue
      USPMCPushSlotReady(slotReady):
        var commit = slotReady.writeItem()
        match commit:
          USPMCPushComplete(completeState):
            discard completeState.extractPinned()
            return
          USPMCPushSegmentLoaded(reLoaded):
            # Reserved-future arm (plan §799 / typestate §305-388 do not
            # currently emit this from writeItem). Rebuild a Ready from
            # the carried pin/queue/pendingItem and re-enter the loop so
            # the next iteration reissues loadSegment -> checkFull. The
            # `match` arm bind is immutable, so copy `pendingItem` to a
            # mutable local before moving it into the rebuilt state.
            var pending = reLoaded.pendingItem
            ready = USPMCPushReady[T, S, MaxThreads](
              pinnedHandle: reLoaded.pinnedHandle,
              pinnedEpoch: reLoaded.pinnedEpoch,
              queue: reLoaded.queue,
              pendingItem: move(pending),
            )
            continue
          USPMCPushSegmentClosed(closedState):
            # Starvation escalation: bridge SegmentClosed -> SegmentFull via
            # closeSegmentDone, then allocate a fresh segment and retry.
            let full = closedState.closeSegmentDone()
            let newSeg = cast[ptr ts_spmc_push.Segment[S, T]](newSegment[S, T]())
            ready = full.allocateNewSegment(newSeg)
            continue

proc push*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads], items: openArray[T]
) =
  ## Push multiple items.
  # Bulk variant: per-iteration single-item call has its own (no-op pin)
  # entry. Stays OUTSIDE any pin scope (R6) — the single-item push has no
  # pin scope to begin with.
  for item in items:
    self.push(item)

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads], handle: ThreadHandle[MaxThreads]
): Consumer[S, T, MaxThreads] =
  ## Register a new consumer and get a handle.
  ##
  ## Returns a Consumer handle for popping items.
  ##
  ## Each consumer sees every item exactly once. Items are distributed
  ## among consumers in arrival order (not broadcast).
  let idx = self.consumerCount.fetchAdd(1, moAcquire)
  assert idx < MaxThreads, "Too many consumers (max " & $MaxThreads & ")"

  result.queue = addr self
  result.idx = idx
  result.localHead = 0
  result.handle = handle

proc getConsumer*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
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

# Typed destructor for retired segments. Generic over `(S, T)` so we can
# `reset` any managed slots (`string`, `seq`, `ref`, ...) before
# `freeAligned`'s away the segment block. For POD `T` (`supportsCopyMem`),
# the loop is compile-time-elided.
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
    cast[ptr ts_spmc_push.UnboundedSipmucBase[S, T, MaxThreads]](addr self.queue[])

  # Single `withPin` around the WHOLE verb loop per design §2.3 (NOT
  # one-pin-per-iteration). The pin lets us call `it.retire(...)` for
  # retired segments — the facade owns segment lifetime via DEBRA so
  # consumers never observe a freed pointer until every pinned thread
  # has rotated past the retirement epoch.
  #
  # DEBRA Pin–Claim Ordering Invariant (Task 11):
  #   1. Pin opens BEFORE headSegment.load (this withPin: scope).
  #   2. Pin covers fetchAdd(consumerHead) → read(data[mySlot]) window.
  #   3. Segment under pin == segment under claim (typestate linearity).
  #   4. headSegment.compareExchange retires oldSeg via DEBRA; oldSeg is
  #      not freed until all pins in its retire-epoch rotate.
  #   5. Bulk variant (L504+) acquires per-iteration pin satisfying 1-4.
  # DO NOT alter withPin scope without re-establishing this invariant.
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
      var loaded =
        ts_spmc_pop.startPop[T, S, MaxThreads](pinned, queueBase).loadSegment()
      when defined(awaitingTailTestHook):
        # Test-only Hook C: gate C1 between snapshot-capture (loadSegment)
        # and snapshot-use (tryClaimSlot). The thread-local
        # `c1IsTheTargetThread` flag is set ONLY by C1's thread proc in
        # the awaitingTail-strand regression test; for every other thread
        # (producer, C2, main-thread driver), the flag is false and the
        # hook is a no-op. Pure wait: Channel.send + Channel.recv only,
        # no algorithm-observable state mutation. The flag itself is
        # test-driver-owned state, never read or written by algorithm
        # code paths, and is elided in production builds along with the
        # rest of this `when defined(...)` block. See
        # `stress-tests/t_unbounded_spmc_awaiting_tail_strand.nim`.
        if c1IsTheTargetThread:
          c1LoadedChan.send(1)
          discard c1ProceedChan.recv()
      var claim = loaded.tryClaimSlot()
      match claim:
        USPMCPopSlotClaimed(slotClaimed):
          # A3: read the public `value*` field directly. The prior
          # `ts_spmc_pop.getValue` wrapper added one generic verb-proc
          # instantiation per (T, S, MT, mm-mode) for no behavioral benefit.
          let complete = slotClaimed.readItem()
          result = some(complete.value)
          break
        USPMCPopClosedSlot(closedSlot):
          # Task 10a (LIVE, 2026-05-15): consumer's close-CAS in
          # `tryClaimSlot` won on an empty cell — the over-claim
          # resolution path. `pop()` returns `none(T)` without
          # advancing headSegment; the producer's later publish on
          # this slot will fail its CAS, recover its `pending` value,
          # and retry on the next slot (see
          # `unbounded_spmc_push.nim:392-412`).
          #
          # Hook A re-anchor (Task 10a amendment 2026-05-15): this is
          # the new awaitingTail-strand deterministic interleave site.
          # Task 9 deleted the prior `if exhausted.awaitingTail:` site;
          # under LCRQ, the close-CAS-wins branch is the natural
          # observation point for "C1 has reached the strand site with
          # its pin still held". The hook is a pure wait
          # (Channel.send + Channel.recv only); no algorithm-observable
          # state mutation. Compile-gated by `-d:awaitingTailTestHook`.
          when defined(awaitingTailTestHook):
            awaitingTailReachedChan.send(1)
            discard awaitingTailGoChan.recv()
          # I-1 (Pin-leak preservation): MUST `break`, not `return`.
          # This arm sits inside the `withPin:` scope opened above;
          # `return` short-circuits the scope and skips the implicit
          # unpin, leaking a DEBRA pin per call. Pins accumulate, the
          # epoch can never advance, and consumers livelock spinning
          # inside `unpin`. `break` exits the inner while-loop,
          # allowing the withPin scope to terminate naturally;
          # `result = none(T)` gives the proc its return value.
          # See `src/lockfreequeues/typestates/unbounded_spmc_pop.nim`
          # `extractPinned*(USPMCPopClosedSlot)` overload.
          discard closedSlot.extractPinned()
          result = none(T)
          break
        USPMCPopSegmentExhausted(exhausted):
          # Task 9: SegmentExhausted no longer carries `awaitingTail`.
          # The over-claim race (formerly `awaitingTail=true`) is
          # currently emitted as SegmentExhausted by `tryClaimSlot`
          # (placeholder); Task 10a replaces that emit with the
          # USPMCPopClosedSlot arm above.
          #
          # Capture the old segment pointer BEFORE the typestate consumes
          # the state — the facade owns segment lifetime and DEBRA-retires
          # the old segment when it wins the headSegment CAS.
          let oldSeg = cast[ptr Segment[S, T]](exhausted.segment)
          var advance = exhausted.advanceSegment()
          match advance:
            USPMCPopEmpty(_):
              # Transient miss: when oldSeg.next == nil at the load below but
              # the producer publishes immediately after, this pop returns none
              # for one call. The outer pop()/getConsumer() loop re-enters and
              # observes the new state on the next iteration. Working as designed
              # for non-blocking SPMC; not a livelock.
              # I-1 (Pin-leak preservation): inside `withPin:` scope —
              # MUST `break`, not `return`. `result` defaults to `none(T)`.
              break
            USPMCPopReady(_):
              # F1' RESHAPED (Task 11, D2 = DEBRA pin-based retirement
              # gating).
              #
              # Correctness is OWNED BY the DEBRA Pin–Claim Ordering
              # Invariant documented above the verb-loop `withPin:` scope.
              # The check below is a PERFORMANCE OPTIMIZATION — it avoids
              # a wasted CAS-retire when unclaimed slots may remain on
              # oldSeg. It is NOT a TOCTOU defense.
              #
              # Background: the producer's invariant is that
              # `oldSeg.next.store(newSeg, moRelease)` happens AFTER
              # `oldSeg.tail` reaches `S` (the segment is full). The
              # acquire-load on `oldSeg.next` (already performed inside
              # `advanceSegment`) establishes happens-before with that
              # release-store, so a fresh acquire-load of `consumerHead`
              # here observes the latest fetchAdd state. Under the new
              # next-claimable semantics, `consumerHead < S` means at
              # least one slot has not yet been claimed (free-claim).
              # Spinning on this segment instead of advancing avoids a
              # head-CAS-then-retire race against still-pending consumers.
              let freshConsumerHead = oldSeg.consumerHead.load(moAcquire)
              if freshConsumerHead < S:
                # Unclaimed slots remain in oldSeg. Skip the head CAS
                # and retire — loop back to re-load and try to claim.
                backoffOnCASLossRetry()
                continue
              # Try to be the thread that retires this segment by CAS-
              # advancing headSegment from oldSeg to the next segment.
              # The winner retires; the loser observes that another
              # consumer already advanced and continues. Mirrors the
              # consumer-vs-consumer coordination the previous direct
              # production code performed at the head-advance site.
              let nextSeg = cast[ptr Segment[S, T]](oldSeg.next.load(moAcquire))
              var expected = oldSeg
              if self.queue.headSegment.compareExchange(
                expected, nextSeg, moAcquireRelease, moAcquire
              ):
                # Always retire so DEBRA owns the detached segment: Manual
                # leaves it in limbo for `tryReclaim` (or
                # `manager.=destroy` at scope exit) to drain; Eager
                # reclaims it shortly via the `reclaimNow` call after the
                # pin block. Without retiring, the segment is detached
                # from the head chain but reachable from no root, and
                # leaks at process exit.
                it.retire(cast[pointer](oldSeg), segmentDestructor[S, T])
                if self.queue.strategy != Manual:
                  discard self.queue.segments.fetchSub(1, moRelaxed)
              # CAS-loss-retry on segment-advance (consumer-vs-consumer
              # headSegment CAS).
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

  # Bulk variant runs OUTSIDE withPin; each iteration acquires its own pin.
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
      self: var UnboundedSipmuc[S, T, MaxThreads]
  ): pointer =
    ## Test-only accessor: returns the queue's current head segment pointer
    ## so the cache-line padding audit can verify base alignment.
    result = cast[pointer](self.headSegment.load(moRelaxed))

  proc segmentHeadOffsetForTest*[S: static int, T; MaxThreads: static int](
      _: typedesc[UnboundedSipmuc[S, T, MaxThreads]]
  ): tuple[tail: int, consumerHead: int, cellState: int, closed: int] =
    ## Test-only accessor: returns offsets of cache-line-padded fields within
    ## the unbounded sipmuc Segment for the cache-line padding audit.
    result = (offsetOf(Segment[S, T], tail), offsetOf(Segment[S, T], consumerHead),
              offsetOf(Segment[S, T], cellState), offsetOf(Segment[S, T], closed))

proc `=destroy`*[S: static int, T; MaxThreads: static int](
    self: var UnboundedSipmuc[S, T, MaxThreads]
) =
  ## Clean up all segments. Releases this queue's client refcount on
  ## the manager; if the queue owns a private manager (auto-create
  ## overload), tears that manager down and frees it.
  var seg = self.headSegment.load(moRelaxed)
  while seg != nil:
    when not supportsCopyMem(T):
      # Run the destructor for any managed slots (string/seq/ref) before
      # `freeAligned`'s away the segment block — otherwise their internal
      # allocations leak.
      for i in 0 ..< S:
        reset(seg.data[i])
    let next = seg.next.load(moRelaxed)
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
