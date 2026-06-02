## UnboundedMpmc throughput bench (split).
##
## Carved out of the legacy `bench_unbounded.nim` to eliminate
## cross-family iCache contention — mirrors the 37aa1c5 mitigation
## applied to `bench_mpmc.nim`. See `bench_unbounded_spsc.nim`'s
## header for the full diagnostic context.
##
## Covers UnboundedMpmc (N producers + N consumers, DEBRA epoch
## reclamation) at the {1,2,4}P x {1,2,4}C grid (9 shapes); also
## carries the MVP comparison adapters whose slug shape matches the
## Mpmc unbounded grid (Loony, Crossbeam SegQueue, MoodyCamel),
## each gated by per-library `-d:adapter_<lib>_available`.
##
## Per-binary intdefines (shared with the other bench_unbounded_*
## binaries so existing CI overrides continue to work unchanged):
##   -d:UnboundedMpmcRuns          (default 3)
##   -d:UnboundedMpmcMessageCount  (default 500_000)
##   -d:BenchUnboundedWarmup         (default 2)
##
## When `-d:BenchSkipOversubscribed` is set, shapes with `P + C > 4`
## are dropped (round-robin consumer ordering hangs under 4-vCPU
## oversubscription).

import std/[atomics, monotimes, options, os, parseopt, sets, strformat,
            syncio, times]
import ./bench_common
import lockfreequeues/backoff
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags
from debra import DebraManager, initDebraManager

# Comparison adapters. Loony, Crossbeam SegQueue, MoodyCamel are
# unbounded MPMC; all go through runThroughputHarness over the
# {1,2,4} P x {1,2,4} C grid.
when defined(adapter_loony_available):
  import ./adapters/loony_adapter

when defined(adapter_crossbeam_seg_queue_available):
  import ./adapters/crossbeam_seg_queue_adapter

when defined(adapter_moodycamel_available):
  import ./adapters/moodycamel_adapter

# Tier 2 Rust comparison adapters: flume + kanal unbounded channels. Both go through runThroughputHarness over the
# {1,2,4} P x {1,2,4} C grid.
when defined(adapter_flume_available):
  import ./adapters/flume_adapter

when defined(adapter_kanal_available):
  import ./adapters/kanal_adapter

const
  UnboundedMpmcRuns* {.intdefine.} = 3
  UnboundedMpmcMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  MaxThreads = 16

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedMpmcRuns == 3
    doAssert UnboundedMpmcMessageCount == 500_000

# ---------- UnboundedMpmc harness (N producers, N consumers, DEBRA) ----------

type
  UMpmcQueueT[S: static int; T; MaxT: static int] =
    Queue[T, ccMulti, ccMulti, stEager, S, MaxT]

  UMpmcProducerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UMpmcQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccMulti]
    startIdx: int
    count: int
    id: int
      ## Stable producer index used by -d:benchProgress logging.

  UMpmcConsumerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UMpmcQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccMulti]
    count: int
    id: int
      ## Stable consumer index used by -d:benchProgress logging.

when defined(benchProgress):
  # Per-10k progress prints (opt-in via -d:benchProgress) for triaging
  # intermittent CI hangs. See bench_unbounded_spsc.nim for context.
  # `benchShape` is written by `runUMpmcShape` before any worker thread
  # is created and read-only thereafter, so a plain global is sufficient.
  var benchShape: string
  proc benchProgress(adapter, tag: string, n: int) =
    echo "[" & adapter & " " & benchShape & " " & tag & "=" & $n & "]"
    flushFile(stdout)

proc umpmcProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMpmcProducerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var producer = ctx.queue[].getProducerHere()
    # Register this producer's debra handle on its own thread.
    # No try/except around `attach()`: `MaxT == MaxThreads == 16` (see
    # the top-of-file constant) bounds the registration capacity above
    # the largest shape this binary exercises (`4p4c` + main + consumer
    # threads = 9 attach() calls), so `DebraRegistrationError` is
    # unreachable here by construction.
    when defined(benchProgress):
      var pushed = 0
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      producer.push(T(i))
      when defined(benchProgress):
        inc pushed
        if pushed mod 10_000 == 0:
          benchProgress("unbounded_mpmc", "p" & $ctx.id & " pushed", pushed)

proc umpmcConsumerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMpmcConsumerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var consumer = ctx.queue[].getConsumerHere()
    # Register this consumer's debra handle on its own thread. Same
    # `MaxT == 16` rationale as the producer thread above: no
    # try/except is needed because debra registration exhaustion is
    # unreachable for the shapes this binary exercises.
    var local = 0
    while local < ctx.count:
      let r = consumer.pop()
      if r.isSome:
        inc local
        when defined(benchProgress):
          if local mod 10_000 == 0:
            benchProgress("unbounded_mpmc", "c" & $ctx.id & " popped", local)
      else:
        benchBackoffOnPeerWait()

proc runOneUMpmcRun[S: static int; T; MaxT: static int;
                      P: static int; C: static int](
    queue: ptr UMpmcQueueT[S, T, MaxT],
    manager: ptr DebraManager[MaxT, debra.ccMulti],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr UMpmcProducerCtx[S, T, MaxT]]]
  var consumerThreads: array[C, Thread[ptr UMpmcConsumerCtx[S, T, MaxT]]]
  var producerCtxs: array[P, UMpmcProducerCtx[S, T, MaxT]]
  var consumerCtxs: array[C, UMpmcConsumerCtx[S, T, MaxT]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = UMpmcProducerCtx[S, T, MaxT](
      queue: queue, manager: manager,
      startIdx: nextStart, count: count, id: i,
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = UMpmcConsumerCtx[S, T, MaxT](
      queue: queue, manager: manager, count: count, id: i,
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      umpmcProducerThread[S, T, MaxT],
      addr producerCtxs[i],
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      umpmcConsumerThread[S, T, MaxT],
      addr consumerCtxs[i],
    )
  for i in 0 ..< P: joinThread(producerThreads[i])
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUMpmcShape[P: static int; C: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_mpmc/mpmc_unbounded/" &
    $P & "p" & $C & "c"
  echo fmt"UnboundedMpmc {P}p{C}c ({slug}):"
  when defined(benchProgress):
    benchShape = $P & "p" & $C & "c"
    flushFile(stdout)
  for _ in 0 ..< warmup:
    var manager = create(DebraManager[MaxThreads, debra.ccMulti])
    wasMoved(manager[])
    manager[] = initDebraManager[MaxThreads, debra.ccMulti]()
    var q =
      newUnboundedMpmcQueue[uint64, stEager, SegmentSize, MaxThreads](manager)
    discard runOneUMpmcRun[SegmentSize, uint64, MaxThreads, P, C](
      addr q, manager, messageCount)
    reset(q)
    reset(manager[])
    dealloc(manager)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var manager = create(DebraManager[MaxThreads, debra.ccMulti])
    wasMoved(manager[])
    manager[] = initDebraManager[MaxThreads, debra.ccMulti]()
    var q =
      newUnboundedMpmcQueue[uint64, stEager, SegmentSize, MaxThreads](manager)
    samples.add(runOneUMpmcRun[SegmentSize, uint64, MaxThreads, P, C](
      addr q, manager, messageCount))
    reset(q)
    reset(manager[])
    dealloc(manager)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- MVP unbounded MPMC adapter dispatch ----------

when defined(adapter_loony_available):
  proc initLoonyQ(capacity: int): LoonyAdapter[uint64] =
    discard capacity
    makeLoonyAdapter[uint64]()

when defined(adapter_crossbeam_seg_queue_available):
  proc initCrossbeamSegQ(capacity: int): CrossbeamSegQueueAdapter[uint64] =
    discard capacity
    makeCrossbeamSegQueueAdapter[uint64]()

when defined(adapter_moodycamel_available):
  proc initMoodycamelQ(capacity: int): MoodycamelAdapter[uint64] =
    makeMoodycamelAdapter[uint64](capacity)

when defined(adapter_flume_available):
  proc initFlumeUnboundedQ(capacity: int): FlumeUnboundedAdapter[uint64] =
    discard capacity
    makeFlumeUnboundedAdapter[uint64]()

when defined(adapter_kanal_available):
  proc initKanalUnboundedQ(capacity: int): KanalUnboundedAdapter[uint64] =
    discard capacity
    makeKanalUnboundedAdapter[uint64]()

proc runMvpUnboundedShape[A](
    em: var BMFEmitter,
    slugPrefix: string,
    queueInit: proc(capacity: int): A,
    p, c: int,
    runs, warmup, messageCount: int,
) =
  let slug = slugPrefix & "/mpmc_unbounded/" & $p & "p" & $c & "c"
  echo fmt"{slug}:"
  let metrics = runThroughputHarness[A](
    queueInit = queueInit,
    capacity = 0,
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
  result = @["unbounded_mpmc"]
  when declared(initLoonyQ):
    result.add("loony")
  when declared(initCrossbeamSegQ):
    result.add("crossbeam_seg_queue")
  when declared(initMoodycamelQ):
    result.add("moodycamel")
  when declared(initFlumeUnboundedQ):
    result.add("flume_unbounded")
  when declared(initKanalUnboundedQ):
    result.add("kanal_unbounded")

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_mpmc":
    runUMpmcShape[1, 1](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
      UnboundedMpmcMessageCount)
    runUMpmcShape[1, 2](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
      UnboundedMpmcMessageCount)
    runUMpmcShape[2, 1](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
      UnboundedMpmcMessageCount)
    runUMpmcShape[2, 2](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
      UnboundedMpmcMessageCount)
    when not defined(BenchSkipOversubscribed):
      runUMpmcShape[1, 4](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
        UnboundedMpmcMessageCount)
      runUMpmcShape[2, 4](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
        UnboundedMpmcMessageCount)
      runUMpmcShape[4, 1](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
        UnboundedMpmcMessageCount)
      runUMpmcShape[4, 2](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
        UnboundedMpmcMessageCount)
      runUMpmcShape[4, 4](em, UnboundedMpmcRuns, BenchUnboundedWarmup,
        UnboundedMpmcMessageCount)
  else:
    when declared(initLoonyQ):
      if variant == "loony":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[LoonyAdapter[uint64]](
              em, "loony", initLoonyQ,
              p, c, UnboundedMpmcRuns, BenchUnboundedWarmup,
              UnboundedMpmcMessageCount)
        return
    when declared(initCrossbeamSegQ):
      if variant == "crossbeam_seg_queue":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[CrossbeamSegQueueAdapter[uint64]](
              em, "crossbeam_seg_queue", initCrossbeamSegQ,
              p, c, UnboundedMpmcRuns, BenchUnboundedWarmup,
              UnboundedMpmcMessageCount)
        return
    when declared(initMoodycamelQ):
      if variant == "moodycamel":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[MoodycamelAdapter[uint64]](
              em, "moodycamel", initMoodycamelQ,
              p, c, UnboundedMpmcRuns, BenchUnboundedWarmup,
              UnboundedMpmcMessageCount)
        return
    when declared(initFlumeUnboundedQ):
      if variant == "flume_unbounded":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[FlumeUnboundedAdapter[uint64]](
              em, "flume_unbounded", initFlumeUnboundedQ,
              p, c, UnboundedMpmcRuns, BenchUnboundedWarmup,
              UnboundedMpmcMessageCount)
        return
    when declared(initKanalUnboundedQ):
      if variant == "kanal_unbounded":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[KanalUnboundedAdapter[uint64]](
              em, "kanal_unbounded", initKanalUnboundedQ,
              p, c, UnboundedMpmcRuns, BenchUnboundedWarmup,
              UnboundedMpmcMessageCount)
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

  echo "UnboundedMpmc Throughput Benchmark"
  echo "===================================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
