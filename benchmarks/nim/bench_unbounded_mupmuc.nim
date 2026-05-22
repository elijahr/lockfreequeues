## UnboundedMupmuc throughput bench (v5.0.0 3.3.9-D split).
##
## Carved out of the legacy `bench_unbounded.nim` to eliminate
## cross-family iCache contention — mirrors the 37aa1c5 mitigation
## applied to `bench_mpmc.nim`. See `bench_unbounded_sipsic.nim`'s
## header for the full diagnostic context.
##
## Covers UnboundedMupmuc (N producers + N consumers, DEBRA epoch
## reclamation) at the {1,2,4}P x {1,2,4}C grid (9 shapes); also
## carries the MVP comparison adapters whose slug shape matches the
## Mupmuc unbounded grid (Loony, Crossbeam SegQueue, MoodyCamel),
## each gated by per-library `-d:adapter_<lib>_available`.
##
## Per-binary intdefines (shared with the other bench_unbounded_*
## binaries so existing CI overrides continue to work unchanged):
##   -d:UnboundedMupmucRuns          (default 3)
##   -d:UnboundedMupmucMessageCount  (default 500_000)
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
from debra import DebraManager, initDebraManager

# MVP comparison adapters (Track 3 / 4 §4.6). Loony, Crossbeam
# SegQueue, MoodyCamel are unbounded MPMC; all go through
# runThroughputHarness over the {1,2,4} P x {1,2,4} C grid.
when defined(adapter_loony_available):
  import ./adapters/loony_adapter

when defined(adapter_crossbeam_seg_queue_available):
  import ./adapters/crossbeam_seg_queue_adapter

when defined(adapter_moodycamel_available):
  import ./adapters/moodycamel_adapter

const
  UnboundedMupmucRuns* {.intdefine.} = 3
  UnboundedMupmucMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  MaxThreads = 16

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedMupmucRuns == 3
    doAssert UnboundedMupmucMessageCount == 500_000

# ---------- UnboundedMupmuc harness (N producers, N consumers, DEBRA) ----------

type
  UMupmucQueueT[S: static int; T; MaxT: static int] =
    Queue[T, ccMulti, ccMulti, stEager, rkEbr, 0, 0, 0, S, MaxT]

  UMupmucProducerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UMupmucQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccMulti]
    startIdx: int
    count: int

  UMupmucConsumerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UMupmucQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccMulti]
    count: int

proc umupmucProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMupmucProducerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var producer = ctx.queue[].getProducer()
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      producer.push(T(i))

proc umupmucConsumerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMupmucConsumerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var consumer = ctx.queue[].getConsumer()
    var local = 0
    while local < ctx.count:
      let r = consumer.pop()
      if r.isSome:
        inc local
      else:
        backoffOnPeerWait()

proc runOneUMupmucRun[S: static int; T; MaxT: static int;
                      P: static int; C: static int](
    queue: ptr UMupmucQueueT[S, T, MaxT],
    manager: ptr DebraManager[MaxT, debra.ccMulti],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr UMupmucProducerCtx[S, T, MaxT]]]
  var consumerThreads: array[C, Thread[ptr UMupmucConsumerCtx[S, T, MaxT]]]
  var producerCtxs: array[P, UMupmucProducerCtx[S, T, MaxT]]
  var consumerCtxs: array[C, UMupmucConsumerCtx[S, T, MaxT]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = UMupmucProducerCtx[S, T, MaxT](
      queue: queue, manager: manager,
      startIdx: nextStart, count: count,
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = UMupmucConsumerCtx[S, T, MaxT](
      queue: queue, manager: manager, count: count,
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      umupmucProducerThread[S, T, MaxT],
      addr producerCtxs[i],
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      umupmucConsumerThread[S, T, MaxT],
      addr consumerCtxs[i],
    )
  for i in 0 ..< P: joinThread(producerThreads[i])
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUMupmucShape[P: static int; C: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/" &
    $P & "p" & $C & "c"
  echo fmt"UnboundedMupmuc {P}p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var manager = create(DebraManager[MaxThreads, debra.ccMulti])
    manager[] = initDebraManager[MaxThreads, debra.ccMulti]()
    var q =
      newUnboundedMupmucQueue[uint64, stEager, SegmentSize, MaxThreads](manager)
    discard runOneUMupmucRun[SegmentSize, uint64, MaxThreads, P, C](
      addr q, manager, messageCount)
    reset(q)
    reset(manager[])
    dealloc(manager)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var manager = create(DebraManager[MaxThreads, debra.ccMulti])
    manager[] = initDebraManager[MaxThreads, debra.ccMulti]()
    var q =
      newUnboundedMupmucQueue[uint64, stEager, SegmentSize, MaxThreads](manager)
    samples.add(runOneUMupmucRun[SegmentSize, uint64, MaxThreads, P, C](
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
  result = @["unbounded_mupmuc"]
  when declared(initLoonyQ):
    result.add("loony")
  when declared(initCrossbeamSegQ):
    result.add("crossbeam_seg_queue")
  when declared(initMoodycamelQ):
    result.add("moodycamel")

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_mupmuc":
    runUMupmucShape[1, 1](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    runUMupmucShape[1, 2](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    runUMupmucShape[2, 1](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    runUMupmucShape[2, 2](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    when not defined(BenchSkipOversubscribed):
      runUMupmucShape[1, 4](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[2, 4](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[4, 1](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[4, 2](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[4, 4](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
  else:
    when declared(initLoonyQ):
      if variant == "loony":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[LoonyAdapter[uint64]](
              em, "loony", initLoonyQ,
              p, c, UnboundedMupmucRuns, BenchUnboundedWarmup,
              UnboundedMupmucMessageCount)
        return
    when declared(initCrossbeamSegQ):
      if variant == "crossbeam_seg_queue":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[CrossbeamSegQueueAdapter[uint64]](
              em, "crossbeam_seg_queue", initCrossbeamSegQ,
              p, c, UnboundedMupmucRuns, BenchUnboundedWarmup,
              UnboundedMupmucMessageCount)
        return
    when declared(initMoodycamelQ):
      if variant == "moodycamel":
        for p in [1, 2, 4]:
          for c in [1, 2, 4]:
            runMvpUnboundedShape[MoodycamelAdapter[uint64]](
              em, "moodycamel", initMoodycamelQ,
              p, c, UnboundedMupmucRuns, BenchUnboundedWarmup,
              UnboundedMupmucMessageCount)
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

  echo "UnboundedMupmuc Throughput Benchmark"
  echo "===================================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
