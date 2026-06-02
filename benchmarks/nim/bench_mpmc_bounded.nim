## Bounded Mpmc throughput bench .
##
## Carved out of the legacy `bench_mpmc.nim` to eliminate cross-family
## iCache contention. See `bench_spmc_bounded.nim`'s header for the full
## diagnostic context; in short, co-compiling the legacy + Queue
## Spmc paths alongside the Mpmc grid in a single release binary
## produced a -39.6% ± 1.2% throughput artifact on
## `spmc/mpmc/1p1c` even though the generated C for Queue's SPMC pop
## was byte-for-byte identical to the legacy Spmc pop.
##
## This binary covers the Mpmc + Queue-bounded-mpmc families plus
## the non-lockfreequeues comparison adapters whose slug shape matches
## the Mpmc grid:
##
##   - Mpmc (lockfreequeues, multi-producer + multi-consumer): the
##     full {1,2,4}p x {1,2,4}c grid PLUS the 8p8c oversubscription
##     case (issue #15 livelock regression coverage).
##   - Queue (ccMulti x ccMulti, stEager, rkNone) parity: same shape
##     set as Mpmc; slug
##     `lockfreequeues_queue_bounded_mpmc/mpmc/<P>p<C>c`.
##   - nim_channels (Nim system Channel, MPMC): shapes
##     `{1,2,4}p x {1,2,4}c`.
##   - MVP comparison adapters (Boost.LockFree, Crossbeam ArrayQueue,
##     threading.Chan) at `{1,2,4}p x {1,2,4}c`, gated by per-library
##     `-d:adapter_<lib>_available`.
##
## The companion `bench_spmc_bounded.nim` carries the Spmc + Queue-
## bounded-spmc shapes. After `merge_bmf.py` unions both BMF
## fragments the resulting JSON is identical (modulo per-shape numeric
## values) to what the pre-split `bench_mpmc` emitted, so downstream
## tooling (superset_check, bencher upload, chart consumption) needs
## no schema changes.
##
## Per-binary intdefines (design §2.5; shared with bench_spmc_bounded
## so existing CI overrides continue to work unchanged):
##   -d:BenchMpmcRuns=<N>          (default 33)
##   -d:BenchMpmcMessageCount=<N>  (default 1_000_000)
##   -d:BenchMpmcWarmup=<N>        (default 3)

import std/[monotimes, options, os, parseopt, sets, strformat, syncio, times]
import ./bench_common
import ./adapters/channels_adapter
import lockfreequeues/backoff
# The legacy `lockfreequeues/mpmc` module has been deleted; the "mpmc"
# variant below now drives the unified
# `BQueue[T, ccMulti, ccMulti, N, P, C]` generic
# via the smart-constructor `newMpmcQueue` / `initQueue`. The legacy
# variant slug + measure shape are preserved verbatim; the queue_bounded
# parity variant below uses the same underlying generic at the same
# Queue instantiation (semantically redundant post-deletion but kept so
# the historical slug set remains stable for downstream consumers).
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

# Comparison adapters, gated by per-library defines.
when defined(adapter_boost_lockfree_queue_available):
  import ./adapters/boost_lockfree_queue_adapter

when defined(adapter_crossbeam_array_queue_available):
  import ./adapters/crossbeam_array_queue_adapter

# Comparison adapter: Nimble threading.Chan wired here under the MPMC
# slot. Non-blocking trySend/tryRecv.
when defined(adapter_threading_channels_available):
  import ./adapters/threading_channels_adapter

# Tier 1 vendored comparison adapters (header-only C++).
# atomic_queue is general MPMC (registered here at the {1,2,4} P x {1,2,4}
# C grid); rigtorp_mpmc is Vyukov-style bounded MPMC.
when defined(adapter_atomic_queue_available):
  import ./adapters/atomic_queue_adapter

when defined(adapter_rigtorp_mpmc_available):
  import ./adapters/rigtorp_mpmc_adapter

# Tier 2 Rust comparison adapters (flume + kanal, bounded variants).
when defined(adapter_flume_available):
  import ./adapters/flume_adapter

when defined(adapter_kanal_available):
  import ./adapters/kanal_adapter

# Tier 3 vendored adapter: liblfds 7.1.1 (C library,
# license-verified). The adapter routes the MPMC topology to the
# upstream `lfds711_queue_bmm_*` Vyukov-style bounded MPMC queue.
when defined(adapter_liblfds_available):
  import ./adapters/liblfds_adapter

const
  BenchMpmcRuns* {.intdefine.} = 33
  BenchMpmcMessageCount* {.intdefine.} = 1_000_000
  BenchMpmcWarmup* {.intdefine.} = 3

when defined(BenchMpmcTestCompileTime):
  static:
    doAssert BenchMpmcRuns == 33,
      "BenchMpmcRuns default must be 33 (got " & $BenchMpmcRuns & ")"
    doAssert BenchMpmcMessageCount == 1_000_000,
      "BenchMpmcMessageCount default must be 1_000_000 (got " &
      $BenchMpmcMessageCount & ")"
    doAssert BenchMpmcWarmup == 3,
      "BenchMpmcWarmup default must be 3 (got " & $BenchMpmcWarmup & ")"

const
  MpmcCapacity = 1024
  ChannelsCapacity = 1024

# ---------- Mpmc bespoke harness ----------

type
  # Unified BQueue[T, ccMulti, ccMulti, N, P, C]
  # instantiation alias — replaces legacy `Mpmc[N, P, C, T]`.
  MpmcQueueT[N, P, C: static int; T] =
    BQueue[T, ccMulti, ccMulti, N, P, C]
  MpmcProducerT[N, P, C: static int; T] =
    Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
  MpmcConsumerT[N, P, C: static int; T] =
    Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]

  MpmcProducerCtx[N, P, C: static int; T] = object
    producer: MpmcProducerT[N, P, C, T]
    startIdx: int
    count: int

  MpmcConsumerCtx[N, P, C: static int; T] = object
    consumer: MpmcConsumerT[N, P, C, T]
    count: int

proc mpmcProducerThread[N, P, C: static int; T](
    ctx: ptr MpmcProducerCtx[N, P, C, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.producer.push(T(i)):
      benchBackoffOnPeerWait()

proc mpmcConsumerThread[N, P, C: static int; T](
    ctx: ptr MpmcConsumerCtx[N, P, C, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.consumer.pop()
    if item.isSome:
      inc local
    else:
      benchBackoffOnPeerWait()

proc runOneMpmcRun[N, P, C: static int; T](
    queue: var MpmcQueueT[N, P, C, T], messageCount: int
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr MpmcProducerCtx[N, P, C, T]]]
  var consumerThreads: array[C, Thread[ptr MpmcConsumerCtx[N, P, C, T]]]
  var producerCtxs: array[P, MpmcProducerCtx[N, P, C, T]]
  var consumerCtxs: array[C, MpmcConsumerCtx[N, P, C, T]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = MpmcProducerCtx[N, P, C, T](
      producer: queue.getProducerHere(idx = i),
      startIdx: nextStart,
      count: count,
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = MpmcConsumerCtx[N, P, C, T](
      consumer: queue.getConsumerHere(idx = i),
      count: count,
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      mpmcProducerThread[N, P, C, T],
      addr producerCtxs[i],
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      mpmcConsumerThread[N, P, C, T],
      addr consumerCtxs[i],
    )
  for i in 0 ..< P: joinThread(producerThreads[i])
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runMpmcShape[N, P, C: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_mpmc/mpmc/" & $P & "p" & $C & "c"
  echo fmt"Mpmc {P}p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var q = q_mod.newBQueue[T, ccMulti, ccMulti, N, P, C]()
    discard runOneMpmcRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = q_mod.newBQueue[T, ccMulti, ccMulti, N, P, C]()
    samples.add(runOneMpmcRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- BQueue ccMulti x ccMulti harness ----------
#
# Slug `lockfreequeues_queue_bounded_mpmc/mpmc/<P>p<C>c`. Output
# metric / units (throughput_ops_ms) match the legacy Mpmc baseline.

type
  QBoundedMpmcProducerCtx[N, P, C: static int; T] = object
    producer: Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
    startIdx: int
    count: int

  QBoundedMpmcConsumerCtx[N, P, C: static int; T] = object
    consumer: Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccMulti, N, P, C]]
    count: int

proc qBoundedMpmcProducerThread[N, P, C: static int; T](
    ctx: ptr QBoundedMpmcProducerCtx[N, P, C, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.producer.push(T(i)):
      benchBackoffOnPeerWait()

proc qBoundedMpmcConsumerThread[N, P, C: static int; T](
    ctx: ptr QBoundedMpmcConsumerCtx[N, P, C, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.consumer.pop()
    if item.isSome:
      inc local
    else:
      benchBackoffOnPeerWait()

proc runOneQBoundedMpmcRun[N, P, C: static int; T](
    queue: var BQueue[T, ccMulti, ccMulti, N, P, C],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads:
    array[P, Thread[ptr QBoundedMpmcProducerCtx[N, P, C, T]]]
  var consumerThreads:
    array[C, Thread[ptr QBoundedMpmcConsumerCtx[N, P, C, T]]]
  var producerCtxs: array[P, QBoundedMpmcProducerCtx[N, P, C, T]]
  var consumerCtxs: array[C, QBoundedMpmcConsumerCtx[N, P, C, T]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = QBoundedMpmcProducerCtx[N, P, C, T](
      producer: queue.getProducerHere(idx = i),
      startIdx: nextStart,
      count: count,
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = QBoundedMpmcConsumerCtx[N, P, C, T](
      consumer: queue.getConsumerHere(idx = i),
      count: count,
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      qBoundedMpmcProducerThread[N, P, C, T],
      addr producerCtxs[i],
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      qBoundedMpmcConsumerThread[N, P, C, T],
      addr consumerCtxs[i],
    )
  for i in 0 ..< P: joinThread(producerThreads[i])
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runQBoundedMpmcShape[N, P, C: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug =
    "lockfreequeues_queue_bounded_mpmc/mpmc/" & $P & "p" & $C & "c"
  echo fmt"QueueBoundedMpmc {P}p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var q = q_mod.newBQueue[T, ccMulti, ccMulti, N, P, C]()
    discard runOneQBoundedMpmcRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = q_mod.newBQueue[T, ccMulti, ccMulti, N, P, C]()
    samples.add(runOneQBoundedMpmcRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Channels harness (uses runThroughputHarness) ----------

proc initChannelsQ(capacity: int): ChannelsAdapter[uint64] =
  initChannelsAdapter[uint64](capacity)

proc runChannelsShape(
    em: var BMFEmitter,
    p, c: int,
    runs, warmup, messageCount: int,
) =
  let slug = "nim_channels/mpmc/" & $p & "p" & $c & "c"
  echo fmt"Channels {p}p{c}c ({slug}):"
  let metrics = runThroughputHarness[ChannelsAdapter[uint64]](
    queueInit = initChannelsQ,
    capacity = ChannelsCapacity,
    numProducers = p,
    numConsumers = c,
    messageCount = messageCount,
    runCount = runs,
    warmupCount = warmup,
  )
  echo fmt"  mean: {metrics.ops_ms_mean:.1f} ops/ms"
  echo fmt"  stddev: {metrics.ops_ms_stddev:.1f}"
  echo ""
  em.addMeasure(
    slug, "throughput_ops_ms",
    metrics.ops_ms_mean,
    metrics.ops_ms_mean - metrics.ops_ms_stddev,
    metrics.ops_ms_mean + metrics.ops_ms_stddev,
  )

# ---------- MVP adapter dispatch (boost MPMC + crossbeam ArrayQueue) ----------
#
# Both MVP adapters expose push/pop directly so they go through
# runThroughputHarness; the {1,2,4}p x {1,2,4}c grid keeps shape parity
# with the lockfreequeues mpmc baseline (≥ 9 shapes per design 2.4).

when defined(adapter_boost_lockfree_queue_available):
  proc initBoostMpmcQ(capacity: int): BoostLockfreeQueueAdapter[uint64] =
    makeBoostLockfreeQueueAdapter[uint64](capacity)

when defined(adapter_crossbeam_array_queue_available):
  proc initCrossbeamArrayQ(capacity: int): CrossbeamArrayQueueAdapter[uint64] =
    makeCrossbeamArrayQueueAdapter[uint64](capacity)

when defined(adapter_threading_channels_available):
  proc initThreadingChannelsQ(capacity: int): ThreadingChannelsAdapter[uint64] =
    makeThreadingChannelsAdapter[uint64](capacity)

when defined(adapter_atomic_queue_available):
  proc initAtomicQueueMpmcQ(capacity: int): AtomicQueueAdapter[uint64] =
    makeAtomicQueueAdapter[uint64](capacity)

when defined(adapter_rigtorp_mpmc_available):
  proc initRigtorpMpmcQ(capacity: int): RigtorpMpmcAdapter[uint64] =
    makeRigtorpMpmcAdapter[uint64](capacity)

when defined(adapter_flume_available):
  proc initFlumeMpmcQ(capacity: int): FlumeAdapter[uint64] =
    makeFlumeAdapter[uint64](capacity)

when defined(adapter_kanal_available):
  proc initKanalMpmcQ(capacity: int): KanalAdapter[uint64] =
    makeKanalAdapter[uint64](capacity)

when defined(adapter_liblfds_available):
  proc initLiblfdsMpmcQ(capacity: int): LiblfdsAdapter[uint64] =
    # MPMC slot uses the bounded many-producer / many-consumer queue
    # (`lfds711_queue_bmm_*`).
    makeLiblfdsAdapter[uint64](kind = lkBmm, capacity = capacity)

proc runMvpMpmcShape[A](
    em: var BMFEmitter,
    slugPrefix: string,
    queueInit: proc(capacity: int): A,
    p, c: int,
    runs, warmup, messageCount, capacity: int,
) =
  let slug = slugPrefix & "/mpmc/" & $p & "p" & $c & "c"
  echo fmt"{slug}:"
  let metrics = runThroughputHarness[A](
    queueInit = queueInit,
    capacity = capacity,
    numProducers = p,
    numConsumers = c,
    messageCount = messageCount,
    runCount = runs,
    warmupCount = warmup,
  )
  echo fmt"  mean: {metrics.ops_ms_mean:.1f} ops/ms"
  echo fmt"  stddev: {metrics.ops_ms_stddev:.1f}"
  echo fmt"  runs: {metrics.runs}"
  echo ""
  em.addMeasure(
    slug, "throughput_ops_ms",
    metrics.ops_ms_mean,
    metrics.ops_ms_mean - metrics.ops_ms_stddev,
    metrics.ops_ms_mean + metrics.ops_ms_stddev,
  )

# ---------- Variant dispatch ----------

proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["mpmc", "queue_bounded_mpmc", "channels"]
  when declared(initBoostMpmcQ):
    result.add("boost_lockfree_queue")
  when declared(initCrossbeamArrayQ):
    result.add("crossbeam_array_queue")
  when declared(initThreadingChannelsQ):
    result.add("threading_channels")
  when declared(initAtomicQueueMpmcQ):
    result.add("atomic_queue")
  when declared(initRigtorpMpmcQ):
    result.add("rigtorp_mpmc")
  when declared(initFlumeMpmcQ):
    result.add("flume")
  when declared(initKanalMpmcQ):
    result.add("kanal")
  when declared(initLiblfdsMpmcQ):
    result.add("liblfds")

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "mpmc":
    # Full {1,2,4}p x {1,2,4}c grid (9 shapes) — design 2.4 / impl plan 2.5.
    runMpmcShape[MpmcCapacity, 1, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 1, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 1, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 2, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 2, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 2, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 4, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 4, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runMpmcShape[MpmcCapacity, 4, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    # 8p8c: explicit oversubscription regression case for issue #15
    # (CAS-retry livelock fix). Preserved from pre-split bench_throughput.
    runMpmcShape[MpmcCapacity, 8, 8, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  of "queue_bounded_mpmc":
    # Queue parity harness for the full Mpmc shape set.
    runQBoundedMpmcShape[MpmcCapacity, 1, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 1, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 1, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 2, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 2, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 2, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 4, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 4, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 4, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedMpmcShape[MpmcCapacity, 8, 8, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  of "channels":
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        runChannelsShape(em, p, c, BenchMpmcRuns, BenchMpmcWarmup,
                         BenchMpmcMessageCount)
  else:
    when declared(initBoostMpmcQ):
      if variant == "boost_lockfree_queue":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[BoostLockfreeQueueAdapter[uint64]](
              em, "boost_lockfree_queue", initBoostMpmcQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initCrossbeamArrayQ):
      if variant == "crossbeam_array_queue":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[CrossbeamArrayQueueAdapter[uint64]](
              em, "crossbeam_array_queue", initCrossbeamArrayQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initThreadingChannelsQ):
      if variant == "threading_channels":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[ThreadingChannelsAdapter[uint64]](
              em, "threading_channels", initThreadingChannelsQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initAtomicQueueMpmcQ):
      if variant == "atomic_queue":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[AtomicQueueAdapter[uint64]](
              em, "atomic_queue", initAtomicQueueMpmcQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initRigtorpMpmcQ):
      if variant == "rigtorp_mpmc":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[RigtorpMpmcAdapter[uint64]](
              em, "rigtorp_mpmc", initRigtorpMpmcQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initFlumeMpmcQ):
      if variant == "flume":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[FlumeAdapter[uint64]](
              em, "flume", initFlumeMpmcQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initKanalMpmcQ):
      if variant == "kanal":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[KanalAdapter[uint64]](
              em, "kanal", initKanalMpmcQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    when declared(initLiblfdsMpmcQ):
      if variant == "liblfds":
        # Impl plan slug grid: liblfds/mpmc/{1,2,4}p{1,2,4}c (the same
        # 9-shape grid every other MVP MPMC adapter emits).
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpMpmcShape[LiblfdsAdapter[uint64]](
              em, "liblfds", initLiblfdsMpmcQ,
              p, c, BenchMpmcRuns, BenchMpmcWarmup,
              BenchMpmcMessageCount, MpmcCapacity)
        return
    raise newException(ValueError, "unknown variant: " & variant)

when isMainModule:
  setStdIoUnbuffered()

  var bmfOutPath = ""
  var positional: seq[string] = @[]
  block parseCli:
    var p = initOptParser(commandLineParams())
    while true:
      p.next()
      case p.kind
      of cmdEnd: break
      of cmdLongOption, cmdShortOption:
        case p.key
        of "bmf-out":
          if p.val.len == 0:
            echo "Missing value for --bmf-out"
            quit 1
          bmfOutPath = p.val
        else:
          echo "Unknown flag: --", p.key
          quit 1
      of cmdArgument:
        positional.add(p.key)

  let supported = SupportedVariants.toHashSet
  let runVariants =
    if positional.len == 0:
      supported
    else:
      var groups = initHashSet[string]()
      for arg in positional:
        if arg notin supported:
          echo "Unknown variant: ", arg
          echo "Supported: ", SupportedVariants
          quit 1
        groups.incl arg
      groups

  echo "MPMC Mpmc Throughput Benchmark"
  echo "================================"
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
