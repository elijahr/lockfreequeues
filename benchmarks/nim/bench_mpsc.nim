## Bounded MPSC throughput bench (Track 2 PR 2 Task 2.4).
##
## Splits the MPSC slice out of the legacy bench_throughput.nim into a
## standalone binary. Covers Mupsic at `{1,2,4}p1c`. Mupsic requires
## per-thread `Producer` objects obtained via `queue.getProducer(idx)`
## with an explicit `idx`; we pre-assign indices 0..P-1 on the main
## thread and pass the Producer values to the worker threads, mirroring
## the legacy bench_throughput Mupmuc path.
##
## Per-binary intdefines (design §2.5):
##   -d:BenchMpscRuns=<N>          (default 33)
##   -d:BenchMpscMessageCount=<N>  (default 1_000_000)
##   -d:BenchMpscWarmup=<N>        (default 3)
##
## Slug shape: `lockfreequeues_mupsic/mpsc/<P>p1c`. Emitted measure:
## `throughput_ops_ms` (mean, lower=mean-1σ, upper=mean+1σ).

import std/[monotimes, options, os, parseopt, sets, strformat, syncio, times]
import ./bench_common
import lockfreequeues/backoff
import lockfreequeues/mupsic
# v5.0.0 cascade D3.6: parallel exercise of the unified Queue generic
# at MPSC cardinality for B3 parity delta. Bespoke per-shape harness
# below mirrors the Mupsic one. Imports are fine-grained (not the
# umbrella) because the umbrella brings in legacy unbounded modules
# whose `Producer` symbol collides with `mupsic.Producer` above.
import lockfreequeues/queue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

# PR 4 comparison adapter (Track 4 §4.6). Nim's stdlib system.Channel
# wired here under the MPSC slot. Blocking-on-full producer; see the
# adapter file for the apples-to-oranges fairness caveat.
when defined(adapter_nim_channel_available):
  import ./adapters/nim_channel_adapter

const
  BenchMpscRuns* {.intdefine.} = 33
  BenchMpscMessageCount* {.intdefine.} = 1_000_000
  BenchMpscWarmup* {.intdefine.} = 3

when defined(BenchMpscTestCompileTime):
  static:
    doAssert BenchMpscRuns == 33,
      "BenchMpscRuns default must be 33 (got " & $BenchMpscRuns & ")"
    doAssert BenchMpscMessageCount == 1_000_000,
      "BenchMpscMessageCount default must be 1_000_000 (got " &
      $BenchMpscMessageCount & ")"
    doAssert BenchMpscWarmup == 3,
      "BenchMpscWarmup default must be 3 (got " & $BenchMpscWarmup & ")"

const
  MupsicCapacity = 1024
  NimChannelCapacity = 1024

# ---------- Per-shape harness ----------
#
# Mupsic[N, P, T] has P baked in as a static int. For the {1,2,4}p1c
# matrix we instantiate three concrete types and run a bespoke
# producer/consumer harness on each. `runThroughputHarness` cannot drive
# per-thread `Producer` registration, so the harness here mirrors the
# legacy bench_throughput Mupmuc/UnboundedMupsic pattern: pre-assign
# Producer values via `getProducer(idx = i)` on the main thread and
# ship them into worker contexts.

type
  MupsicProducerCtx[N, P: static int; T] = object
    producer: Producer[N, P, T]
    startIdx: int
    count: int

  MupsicConsumerCtx[N, P: static int; T] = object
    queue: ptr Mupsic[N, P, T]
    count: int

proc mupsicProducerThread[N, P: static int; T](
    ctx: ptr MupsicProducerCtx[N, P, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.producer.push(T(i)):
      backoffOnPeerWait()

proc mupsicConsumerThread[N, P: static int; T](
    ctx: ptr MupsicConsumerCtx[N, P, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.queue[].pop()
    if item.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneMupsicRun[N, P: static int; T](
    queue: var Mupsic[N, P, T], messageCount: int
): float =
  ## One run; returns ops/ms. Spread `messageCount mod P` over the first
  ## producers so the per-producer counts sum to messageCount exactly,
  ## matching the runThroughputHarness convention.
  let baseP = messageCount div P
  let remP = messageCount mod P
  var producerThreads: array[P, Thread[ptr MupsicProducerCtx[N, P, T]]]
  var producerCtxs: array[P, MupsicProducerCtx[N, P, T]]
  var consumerThread: Thread[ptr MupsicConsumerCtx[N, P, T]]
  var consumerCtx = MupsicConsumerCtx[N, P, T](
    queue: addr queue, count: messageCount,
  )
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = MupsicProducerCtx[N, P, T](
      producer: queue.getProducer(idx = i),
      startIdx: nextStart,
      count: count,
    )
    nextStart += count
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      mupsicProducerThread[N, P, T],
      addr producerCtxs[i],
    )
  createThread(
    consumerThread,
    mupsicConsumerThread[N, P, T],
    addr consumerCtx,
  )
  for i in 0 ..< P:
    joinThread(producerThreads[i])
  joinThread(consumerThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runMupsicShape[N, P: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_mupsic/mpsc/" & $P & "p1c"
  echo fmt"Mupsic {P}p1c ({slug}):"
  for _ in 0 ..< warmup:
    var q = initMupsic[N, P, T]()
    discard runOneMupsicRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = initMupsic[N, P, T]()
    samples.add(runOneMupsicRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- v5.0.0 cascade D3.6: Queue-based MPSC parity harness ----------
#
# Parallel to the Mupsic harness above, but exercises the unified
# `Queue[uint64, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]`
# generic. Slug `lockfreequeues_queue_bounded_mupsic/mpsc/<P>p1c`.
# Output metric / units (throughput_ops_ms) match the Mupsic baseline
# so B3 can compute a per-shape % delta.

type
  QMpscProducerCtx[N, P: static int; T] = object
    producer: QueueProducer[T, ccMulti, ccSingle, stEager, rkNone,
                            N, P, 0, 0, 0]
    startIdx: int
    count: int

  QMpscConsumerCtx[N, P: static int; T] = object
    queue: ptr Queue[T, ccMulti, ccSingle, stEager, rkNone,
                     N, P, 0, 0, 0]
    count: int

proc qMpscProducerThread[N, P: static int; T](
    ctx: ptr QMpscProducerCtx[N, P, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.producer.push(T(i)):
      backoffOnPeerWait()

proc qMpscConsumerThread[N, P: static int; T](
    ctx: ptr QMpscConsumerCtx[N, P, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.queue[].pop()
    if item.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneQMpscRun[N, P: static int; T](
    queue: var Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  var producerThreads: array[P, Thread[ptr QMpscProducerCtx[N, P, T]]]
  var producerCtxs: array[P, QMpscProducerCtx[N, P, T]]
  var consumerThread: Thread[ptr QMpscConsumerCtx[N, P, T]]
  var consumerCtx = QMpscConsumerCtx[N, P, T](
    queue: addr queue, count: messageCount,
  )
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = QMpscProducerCtx[N, P, T](
      producer: queue.getProducer(idx = i),
      startIdx: nextStart,
      count: count,
    )
    nextStart += count
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      qMpscProducerThread[N, P, T],
      addr producerCtxs[i],
    )
  createThread(
    consumerThread,
    qMpscConsumerThread[N, P, T],
    addr consumerCtx,
  )
  for i in 0 ..< P:
    joinThread(producerThreads[i])
  joinThread(consumerThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runQMpscShape[N, P: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_queue_bounded_mupsic/mpsc/" & $P & "p1c"
  echo fmt"QueueBoundedMupsic {P}p1c ({slug}):"
  for _ in 0 ..< warmup:
    var q = q_mod.initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()
    discard runOneQMpscRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = q_mod.initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()
    samples.add(runOneQMpscRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- PR 4 nim_channel dispatch (uses runThroughputHarness) ----------
#
# system.Channel exposes uniform push/pop through the adapter, so it
# fits the stock runThroughputHarness on the MPSC {1,2,4}p1c matrix
# in parity with the lockfreequeues mupsic baseline.

when defined(adapter_nim_channel_available):
  proc initNimChannelQ(capacity: int): NimChannelAdapter[uint64] =
    makeNimChannelAdapter[uint64](capacity)

  proc runNimChannelShape(
      em: var BMFEmitter,
      p: int,
      runs, warmup, messageCount: int,
  ) =
    let slug = "nim_channel/mpsc/" & $p & "p1c"
    echo fmt"NimChannel {p}p1c ({slug}):"
    let metrics = runThroughputHarness[NimChannelAdapter[uint64]](
      queueInit = initNimChannelQ,
      capacity = NimChannelCapacity,
      numProducers = p,
      numConsumers = 1,
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
  result = @["mupsic", "queue_bounded_mupsic"]
  when declared(initNimChannelQ):
    result.add("nim_channel")

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "mupsic":
    runMupsicShape[MupsicCapacity, 1, uint64](
      em, BenchMpscRuns, BenchMpscWarmup, BenchMpscMessageCount)
    runMupsicShape[MupsicCapacity, 2, uint64](
      em, BenchMpscRuns, BenchMpscWarmup, BenchMpscMessageCount)
    runMupsicShape[MupsicCapacity, 4, uint64](
      em, BenchMpscRuns, BenchMpscWarmup, BenchMpscMessageCount)
  of "queue_bounded_mupsic":
    runQMpscShape[MupsicCapacity, 1, uint64](
      em, BenchMpscRuns, BenchMpscWarmup, BenchMpscMessageCount)
    runQMpscShape[MupsicCapacity, 2, uint64](
      em, BenchMpscRuns, BenchMpscWarmup, BenchMpscMessageCount)
    runQMpscShape[MupsicCapacity, 4, uint64](
      em, BenchMpscRuns, BenchMpscWarmup, BenchMpscMessageCount)
  else:
    when declared(initNimChannelQ):
      if variant == "nim_channel":
        for p in [1, 2, 4]:
          runNimChannelShape(em, p, BenchMpscRuns, BenchMpscWarmup,
                             BenchMpscMessageCount)
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

  echo "MPSC Throughput Benchmark"
  echo "========================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
