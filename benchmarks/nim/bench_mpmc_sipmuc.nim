## Bounded Sipmuc throughput bench (v5.0.0 B3 split).
##
## Carved out of the legacy `bench_mpmc.nim` to eliminate cross-family
## iCache contention. Before the split, the single `bench_mpmc` binary
## co-compiled the Mupmuc grid (10 shapes), the Sipmuc shapes (3),
## the Nim channels grid (9), and up to 27 MVP-adapter shapes into one
## release-mode binary. Manager B3-mitigation's cold-state diagnostic
## (May 2026) showed Queue SPMC pop generated C is byte-for-byte
## identical to the legacy Sipmuc pop, yet a -39.6% ± 1.2% throughput
## gap on `sipmuc/mpmc/1p1c` reproduced ONLY when both paths shared a
## binary. Isolating each family into its own binary removes that
## contention surface at the source.
##
## Covers:
##   - Sipmuc (lockfreequeues, single-producer + multi-consumer):
##     shapes `1p{1,2,4}c`. Sipmuc lives under `mpmc` per design 2.4
##     (single producer is just N=1 of multi-producer).
##   - Queue (ccSingle x ccMulti, stEager, rkNone) parity: same shapes,
##     `lockfreequeues_queue_bounded_sipmuc/mpmc/1p<C>c`.
##
## Per-binary intdefines (design §2.5; shared with the mupmuc binary
## so existing CI overrides continue to work unchanged):
##   -d:BenchMpmcRuns=<N>          (default 33)
##   -d:BenchMpmcMessageCount=<N>  (default 1_000_000)
##   -d:BenchMpmcWarmup=<N>        (default 3)
##
## Output schema mirrors the legacy pre-split bench_mpmc: each shape
## emits one `throughput_ops_ms` measure with mean / mean-1σ / mean+1σ
## bounds. The merge_bmf.py union step recombines this binary's output
## with `bench_mpmc_mupmuc`'s into the same merged BMF the chart and
## bencher upload consume, so no downstream tooling change is required
## beyond enumerating both binaries in place of the pre-split single.

import std/[monotimes, options, os, parseopt, sets, strformat, syncio, times]
import ./bench_common
import lockfreequeues/backoff
# v5.0.0 cascade Step 3.3.8c: the legacy `lockfreequeues/sipmuc` module
# was deleted in 3.3.7; the "sipmuc" variant below now drives the unified
# `BQueue[T, ccSingle, ccMulti, N, 0, C]` generic
# via the smart-constructor `newSipmucQueue` / `initQueue`. The legacy
# variant slug + measure shape are preserved verbatim; the queue_bounded
# parity variant below uses the same underlying generic at the same
# Queue instantiation (semantically redundant post-deletion but kept so
# the B3 cascade slug set remains stable across the 3.3 implementation
# steps).
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub

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

# ---------- Sipmuc bespoke harness ----------
#
# Sipmuc has a single producer (called from the run thread) and C
# consumers. The single-producer push path goes through the queue
# object directly (`var Sipmuc.push`). Each consumer thread takes a
# pre-assigned `Consumer[N, C, T]` value via `getConsumer(idx = i)`.

type
  # Unified BQueue[T, ccSingle, ccMulti, N, 0, C]
  # instantiation alias — replaces legacy `Sipmuc[N, C, T]`.
  SipmucQueueT[N, C: static int; T] =
    BQueue[T, ccSingle, ccMulti, N, 0, C]
  SipmucConsumerT[N, C: static int; T] =
    BQueueConsumer[T, ccSingle, ccMulti, N, 0, C]

  SipmucProducerCtx[N, C: static int; T] = object
    queue: ptr SipmucQueueT[N, C, T]
    startIdx: int
    count: int

  SipmucConsumerCtx[N, C: static int; T] = object
    consumer: SipmucConsumerT[N, C, T]
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
    queue: var SipmucQueueT[N, C, T], messageCount: int
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
    var q = q_mod.newBQueue[T, ccSingle, ccMulti, N, 0, C]()
    discard runOneSipmucRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = q_mod.newBQueue[T, ccSingle, ccMulti, N, 0, C]()
    samples.add(runOneSipmucRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- v5.0.0 cascade D3.6: BQueue ccSingle x ccMulti harness ----------
#
# Slug `lockfreequeues_queue_bounded_sipmuc/mpmc/1p<C>c`. Output metric /
# units (throughput_ops_ms) match the legacy Sipmuc baseline so B3
# parity delta is a simple per-shape division across the two emitted
# measures.

type
  QBoundedSipmucProducerCtx[N, C: static int; T] = object
    queue: ptr BQueue[T, ccSingle, ccMulti, N, 0, C]
    startIdx: int
    count: int

  QBoundedSipmucConsumerCtx[N, C: static int; T] = object
    consumer: BQueueConsumer[T, ccSingle, ccMulti, N, 0, C]
    count: int

proc qBoundedSipmucProducerThread[N, C: static int; T](
    ctx: ptr QBoundedSipmucProducerCtx[N, C, T]
) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not ctx.queue[].push(T(i)):
      backoffOnPeerWait()

proc qBoundedSipmucConsumerThread[N, C: static int; T](
    ctx: ptr QBoundedSipmucConsumerCtx[N, C, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.consumer.pop()
    if item.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneQBoundedSipmucRun[N, C: static int; T](
    queue: var BQueue[T, ccSingle, ccMulti, N, 0, C],
    messageCount: int,
): float =
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThread: Thread[ptr QBoundedSipmucProducerCtx[N, C, T]]
  var producerCtx = QBoundedSipmucProducerCtx[N, C, T](
    queue: addr queue, startIdx: 0, count: messageCount,
  )
  var consumerThreads:
    array[C, Thread[ptr QBoundedSipmucConsumerCtx[N, C, T]]]
  var consumerCtxs: array[C, QBoundedSipmucConsumerCtx[N, C, T]]
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = QBoundedSipmucConsumerCtx[N, C, T](
      consumer: queue.getConsumer(idx = i),
      count: count,
    )
  let startTime = getMonoTime()
  createThread(
    producerThread,
    qBoundedSipmucProducerThread[N, C, T],
    addr producerCtx,
  )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      qBoundedSipmucConsumerThread[N, C, T],
      addr consumerCtxs[i],
    )
  joinThread(producerThread)
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runQBoundedSipmucShape[N, C: static int; T](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_queue_bounded_sipmuc/mpmc/1p" & $C & "c"
  echo fmt"QueueBoundedSipmuc 1p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var q = q_mod.newBQueue[T, ccSingle, ccMulti, N, 0, C]()
    discard runOneQBoundedSipmucRun(q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = q_mod.newBQueue[T, ccSingle, ccMulti, N, 0, C]()
    samples.add(runOneQBoundedSipmucRun(q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Variant dispatch ----------

proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["sipmuc", "queue_bounded_sipmuc"]

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "sipmuc":
    # Single producer x {1,2,4} consumers — design 2.4.
    runSipmucShape[MpmcCapacity, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runSipmucShape[MpmcCapacity, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runSipmucShape[MpmcCapacity, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  of "queue_bounded_sipmuc":
    # v5.0.0 cascade D3.6: Queue parity for the Sipmuc 1p<C>c set.
    runQBoundedSipmucShape[MpmcCapacity, 1, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedSipmucShape[MpmcCapacity, 2, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
    runQBoundedSipmucShape[MpmcCapacity, 4, uint64](
      em, BenchMpmcRuns, BenchMpmcWarmup, BenchMpmcMessageCount)
  else:
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

  echo "MPMC Sipmuc Throughput Benchmark"
  echo "================================"
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
