## UnboundedSipmuc throughput bench (v5.0.0 3.3.9-D split).
##
## Carved out of the legacy `bench_unbounded.nim` to eliminate
## cross-family iCache contention — mirrors the 37aa1c5 mitigation
## applied to `bench_mpmc.nim`. See `bench_unbounded_sipsic.nim`'s
## header for the full diagnostic context.
##
## Covers UnboundedSipmuc (single producer + N consumers, DEBRA epoch
## reclamation) at shapes 1p{1,2,4}c.
##
## Per-binary intdefines (shared with the other bench_unbounded_*
## binaries so existing CI overrides continue to work unchanged):
##   -d:UnboundedSipmucRuns          (default 3)
##   -d:UnboundedSipmucMessageCount  (default 500_000)
##   -d:BenchUnboundedWarmup         (default 2)

import std/[monotimes, options, os, parseopt, sets, strformat,
            syncio, times]
import ./bench_common
import lockfreequeues/backoff
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
from debra import DebraManager, initDebraManager

const
  UnboundedSipmucRuns* {.intdefine.} = 3
  UnboundedSipmucMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  MaxThreads = 16

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedSipmucRuns == 3
    doAssert UnboundedSipmucMessageCount == 500_000

# ---------- UnboundedSipmuc harness (single producer, N consumers, DEBRA) ----------

type
  USipmucQueueT[S: static int; T; MaxT: static int] =
    Queue[T, ccSingle, ccMulti, stEager, S, MaxT]

  USipmucProducerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr USipmucQueueT[S, T, MaxT]
    count: int

  USipmucConsumerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr USipmucQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccMulti]
    count: int

proc usipmucProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr USipmucProducerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducer()
    for i in 0 ..< ctx.count:
      p.push(T(i))

proc usipmucConsumerThread[S: static int; T; MaxT: static int](
    ctx: ptr USipmucConsumerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var consumer = ctx.queue[].getConsumer()
    # Register this consumer's debra handle on its own thread.
    consumer.attach()
    var local = 0
    while local < ctx.count:
      let r = consumer.pop()
      if r.isSome:
        inc local
      else:
        backoffOnPeerWait()

proc runOneUSipmucRun[S: static int; T; MaxT: static int; C: static int](
    queue: ptr USipmucQueueT[S, T, MaxT],
    manager: ptr DebraManager[MaxT, debra.ccMulti],
    messageCount: int,
): float =
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThread: Thread[ptr USipmucProducerCtx[S, T, MaxT]]
  var consumerThreads: array[C, Thread[ptr USipmucConsumerCtx[S, T, MaxT]]]
  var producerCtx = USipmucProducerCtx[S, T, MaxT](
    queue: queue, count: messageCount,
  )
  var consumerCtxs: array[C, USipmucConsumerCtx[S, T, MaxT]]
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = USipmucConsumerCtx[S, T, MaxT](
      queue: queue, manager: manager, count: count,
    )
  let startTime = getMonoTime()
  createThread(producerThread,
               usipmucProducerThread[S, T, MaxT],
               addr producerCtx)
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      usipmucConsumerThread[S, T, MaxT],
      addr consumerCtxs[i],
    )
  joinThread(producerThread)
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUSipmucShape[C: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p" & $C & "c"
  echo fmt"UnboundedSipmuc 1p{C}c ({slug}):"
  for _ in 0 ..< warmup:
    var manager = create(DebraManager[MaxThreads, debra.ccMulti])
    manager[] = initDebraManager[MaxThreads, debra.ccMulti]()
    var q =
      newUnboundedSipmucQueue[uint64, stEager, SegmentSize, MaxThreads](manager)
    discard runOneUSipmucRun[SegmentSize, uint64, MaxThreads, C](
      addr q, manager, messageCount)
    reset(q)
    reset(manager[])
    dealloc(manager)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var manager = create(DebraManager[MaxThreads, debra.ccMulti])
    manager[] = initDebraManager[MaxThreads, debra.ccMulti]()
    var q =
      newUnboundedSipmucQueue[uint64, stEager, SegmentSize, MaxThreads](manager)
    samples.add(runOneUSipmucRun[SegmentSize, uint64, MaxThreads, C](
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

# ---------- Variant dispatch ----------

proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["unbounded_sipmuc"]

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_sipmuc":
    runUSipmucShape[1](em, UnboundedSipmucRuns, BenchUnboundedWarmup,
      UnboundedSipmucMessageCount)
    runUSipmucShape[2](em, UnboundedSipmucRuns, BenchUnboundedWarmup,
      UnboundedSipmucMessageCount)
    when not defined(BenchSkipOversubscribed):
      runUSipmucShape[4](em, UnboundedSipmucRuns, BenchUnboundedWarmup,
        UnboundedSipmucMessageCount)
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

  echo "UnboundedSipmuc Throughput Benchmark"
  echo "===================================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
