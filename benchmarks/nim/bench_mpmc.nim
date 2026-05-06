## Bounded MPMC throughput bench (Track 2 PR 2 Task 2.5).
##
## Splits the MPMC slice out of the legacy bench_throughput.nim into a
## standalone binary. Covers three queue families:
##
##   - Mupmuc (lockfreequeues, multi-producer + multi-consumer): the full
##     {1,2,4} P x {1,2,4} C grid PLUS the 8p8c oversubscription case.
##     8p8c is the issue #15 livelock regression coverage shape and is
##     present in the pre-split bench_throughput fixture; keeping it here
##     preserves the deletion-safety guarantee.
##   - Sipmuc (lockfreequeues, single-producer + multi-consumer): shapes
##     `1p{1,2,4}c`. Sipmuc lives under `mpmc` per design 2.4 (single
##     producer is just N=1 of multi-producer).
##   - nim_channels (Nim system Channel, MPMC): shapes
##     `{1,2,4} P x {1,2,4} C`.
##
## Per-binary intdefines (design §2.5):
##   -d:BenchMpmcRuns=<N>          (default 33)
##   -d:BenchMpmcMessageCount=<N>  (default 1_000_000)
##   -d:BenchMpmcWarmup=<N>        (default 3)
##
## Mupmuc + Sipmuc require per-thread Producer / Consumer objects, so
## those topologies use a bespoke harness (mirrors bench_throughput's
## legacy Mupmuc path); channels exposes a uniform push/pop and uses
## bench_common.runThroughputHarness.

import std/[monotimes, options, os, parseopt, strformat, syncio, times]
import ./bench_common
import ./adapters/channels_adapter
import lockfreequeues/mupmuc
import lockfreequeues/sipmuc
import lockfreequeues/backoff

# MVP comparison adapters (Track 3). Gated by per-library defines.
when defined(adapter_boost_lockfree_queue_available):
  import ./adapters/boost_lockfree_queue_adapter

when defined(adapter_crossbeam_array_queue_available):
  import ./adapters/crossbeam_array_queue_adapter

# PR 4 comparison adapter (Track 4 §4.6). Nimble threading.Chan
# wired here under the MPMC slot. Non-blocking trySend/tryRecv.
when defined(adapter_threading_channels_available):
  import ./adapters/threading_channels_adapter

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

# ---------- Mupmuc bespoke harness ----------

type
  MupmucProducerCtx[N, P, C: static int; T] = object
    producer: MupmucProducer[N, P, C, T]
    startIdx: int
    count: int

  MupmucConsumerCtx[N, P, C: static int; T] = object
    consumer: mupmuc.Consumer[N, P, C, T]
    count: int

proc mupmucProducerThread[N, P, C: static int; T](
    ctx: ptr MupmucProducerCtx[N, P, C, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.producer.push(T(i)):
      backoffOnPeerWait()

proc mupmucConsumerThread[N, P, C: static int; T](
    ctx: ptr MupmucConsumerCtx[N, P, C, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.consumer.pop()
    if item.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneMupmucRun[N, P, C: static int; T](
    queue: var Mupmuc[N, P, C, T], messageCount: int
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr MupmucProducerCtx[N, P, C, T]]]
  var consumerThreads: array[C, Thread[ptr MupmucConsumerCtx[N, P, C, T]]]
  var producerCtxs: array[P, MupmucProducerCtx[N, P, C, T]]
  var consumerCtxs: array[C, MupmucConsumerCtx[N, P, C, T]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = MupmucProducerCtx[N, P, C, T](
      producer: queue.getProducer(idx = i),
      startIdx: nextStart,
      count: count,
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = MupmucConsumerCtx[N, P, C, T](
      consumer: queue.getConsumer(idx = i),
      count: count,
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      mupmucProducerThread[N, P, C, T],
      addr producerCtxs[i],
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      mupmucConsumerThread[N, P, C, T],
      addr consumerCtxs[i],
    )
  for i in 0 ..< P: joinThread(producerThreads[i])
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runMupmucShape[N, P, C: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_mupmuc/mpmc/" & $P & "p" & $C & "c"
  echo fmt"Mupmuc {P}p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var q = initMupmuc[N, P, C, T]()
    discard runOneMupmucRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = initMupmuc[N, P, C, T]()
    samples.add(runOneMupmucRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Sipmuc bespoke harness ----------
#
# Sipmuc has a single producer (called from the run thread) and C
# consumers. The single-producer push path goes through the queue
# object directly (`var Sipmuc.push`). Each consumer thread takes a
# pre-assigned `Consumer[N, C, T]` value via `getConsumer(idx = i)`.

type
  SipmucProducerCtx[N, C: static int; T] = object
    queue: ptr Sipmuc[N, C, T]
    startIdx: int
    count: int

  SipmucConsumerCtx[N, C: static int; T] = object
    consumer: sipmuc.Consumer[N, C, T]
    count: int

proc sipmucProducerThread[N, C: static int; T](
    ctx: ptr SipmucProducerCtx[N, C, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.queue[].push(T(i)):
      backoffOnPeerWait()

proc sipmucConsumerThread[N, C: static int; T](
    ctx: ptr SipmucConsumerCtx[N, C, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.consumer.pop()
    if item.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneSipmucRun[N, C: static int; T](
    queue: var Sipmuc[N, C, T], messageCount: int
): float =
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThread: Thread[ptr SipmucProducerCtx[N, C, T]]
  var producerCtx = SipmucProducerCtx[N, C, T](
    queue: addr queue, startIdx: 0, count: messageCount,
  )
  var consumerThreads: array[C, Thread[ptr SipmucConsumerCtx[N, C, T]]]
  var consumerCtxs: array[C, SipmucConsumerCtx[N, C, T]]
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = SipmucConsumerCtx[N, C, T](
      consumer: queue.getConsumer(idx = i),
      count: count,
    )
  let startTime = getMonoTime()
  createThread(
    producerThread,
    sipmucProducerThread[N, C, T],
    addr producerCtx,
  )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      sipmucConsumerThread[N, C, T],
      addr consumerCtxs[i],
    )
  joinThread(producerThread)
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runSipmucShape[N, C: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_sipmuc/mpmc/1p" & $C & "c"
  echo fmt"Sipmuc 1p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var q = initSipmuc[N, C, T]()
    discard runOneSipmucRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = initSipmuc[N, C, T]()
    samples.add(runOneSipmucRun(q, messageCount))
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
# runThroughputHarness; the {1,2,4} P x {1,2,4} C grid keeps shape parity
# with the lockfreequeues mupmuc baseline (≥ 9 shapes per design 2.4).

when defined(adapter_boost_lockfree_queue_available):
  proc initBoostMpmcQ(capacity: int): BoostLockfreeQueueAdapter[uint64] =
    makeBoostLockfreeQueueAdapter[uint64](capacity)

when defined(adapter_crossbeam_array_queue_available):
  proc initCrossbeamArrayQ(capacity: int): CrossbeamArrayQueueAdapter[uint64] =
    makeCrossbeamArrayQueueAdapter[uint64](capacity)

when defined(adapter_threading_channels_available):
  proc initThreadingChannelsQ(capacity: int): ThreadingChannelsAdapter[uint64] =
    makeThreadingChannelsAdapter[uint64](capacity)

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

# ---------- Adapter procs (topology-based dispatch) ----------

proc runMupmuc(em: var BMFEmitter, topology: Topology) {.nimcall.} =
  discard topology  # informational only; slug grid hardcoded below
  # Full {1,2,4} x {1,2,4} grid (9 shapes) — design 2.4 / impl plan 2.5.
  runMupmucShape[MpmcCapacity, 1, 1, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 1, 2, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 1, 4, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 2, 1, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 2, 2, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 2, 4, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 4, 1, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 4, 2, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runMupmucShape[MpmcCapacity, 4, 4, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  # 8p8c: explicit oversubscription regression case for issue #15
  # (CAS-retry livelock fix). Preserved from pre-split bench_throughput.
  runMupmucShape[MpmcCapacity, 8, 8, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)

proc runSipmuc(em: var BMFEmitter, topology: Topology) {.nimcall.} =
  discard topology
  # Single producer x {1,2,4} consumers — design 2.4. Sipmuc remains on
  # tMpmc here; promotion to tSpmc lands in Commit 2.1 alongside the
  # SPMC topology axis schema change.
  runSipmucShape[MpmcCapacity, 1, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runSipmucShape[MpmcCapacity, 2, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  runSipmucShape[MpmcCapacity, 4, uint64](
    em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)

proc runChannels(em: var BMFEmitter, topology: Topology) {.nimcall.} =
  discard topology
  for p in [1, 2, 4]:
    for c in [1, 2, 4]:
      runChannelsShape(em, p, c, BenchMpmcRuns, BenchMpmcWarmup,
                       BenchMpmcMessageCount)

when declared(initBoostMpmcQ):
  proc runBoostLockfreeQueue(em: var BMFEmitter,
                             topology: Topology) {.nimcall.} =
    discard topology
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        runMvpMpmcShape[BoostLockfreeQueueAdapter[uint64]](
          em, "boost_lockfree_queue", initBoostMpmcQ,
          p, c, BenchMpmcRuns, BenchMpmcWarmup,
          BenchMpmcMessageCount, MpmcCapacity)

when declared(initCrossbeamArrayQ):
  proc runCrossbeamArrayQueue(em: var BMFEmitter,
                              topology: Topology) {.nimcall.} =
    discard topology
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        runMvpMpmcShape[CrossbeamArrayQueueAdapter[uint64]](
          em, "crossbeam_array_queue", initCrossbeamArrayQ,
          p, c, BenchMpmcRuns, BenchMpmcWarmup,
          BenchMpmcMessageCount, MpmcCapacity)

when declared(initThreadingChannelsQ):
  proc runThreadingChannels(em: var BMFEmitter,
                            topology: Topology) {.nimcall.} =
    discard topology
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        runMvpMpmcShape[ThreadingChannelsAdapter[uint64]](
          em, "threading_channels", initThreadingChannelsQ,
          p, c, BenchMpmcRuns, BenchMpmcWarmup,
          BenchMpmcMessageCount, MpmcCapacity)

# ---------- Adapter registry ----------

proc buildAdapters(): seq[Adapter] =
  result.add(Adapter(
    name: "mupmuc",
    topologiesSupported: {tMpmc},
    run: runMupmuc,
  ))
  result.add(Adapter(
    name: "sipmuc",
    topologiesSupported: {tMpmc},  # promoted to tSpmc in Commit 2.1
    run: runSipmuc,
  ))
  result.add(Adapter(
    name: "channels",
    topologiesSupported: {tMpmc},
    run: runChannels,
  ))
  when declared(initBoostMpmcQ):
    result.add(Adapter(
      name: "boost_lockfree_queue",
      topologiesSupported: {tMpmc},
      run: runBoostLockfreeQueue,
    ))
  when declared(initCrossbeamArrayQ):
    result.add(Adapter(
      name: "crossbeam_array_queue",
      topologiesSupported: {tMpmc},
      run: runCrossbeamArrayQueue,
    ))
  when declared(initThreadingChannelsQ):
    result.add(Adapter(
      name: "threading_channels",
      topologiesSupported: {tMpmc},
      run: runThreadingChannels,
    ))

let adapters: seq[Adapter] = buildAdapters()

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

  # Topology filter: see bench_spsc.nim for the rationale.
  var topologyFilter: Option[Topology] = none(Topology)
  if positional.len >= 1:
    try:
      topologyFilter = some(parseTopology(positional[0]))
    except ValueError as e:
      echo "Unknown topology: ", positional[0]
      echo "Reason: ", e.msg
      quit 1

  echo "MPMC Throughput Benchmark"
  echo "========================="
  echo ""

  var emitter = initBMFEmitter()
  for adapter in adapters:
    if topologyFilter.isNone:
      for t in adapter.topologiesSupported:
        adapter.run(emitter, t)
    elif topologyFilter.get in adapter.topologiesSupported:
      adapter.run(emitter, topologyFilter.get)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
