## UnboundedMupsic throughput bench (v5.0.0 3.3.9-D split).
##
## Carved out of the legacy `bench_unbounded.nim` to eliminate
## cross-family iCache contention — mirrors the 37aa1c5 mitigation
## applied to `bench_mpmc.nim`. See `bench_unbounded_sipsic.nim`'s
## header for the full diagnostic context.
##
## Covers UnboundedMupsic (N producers + 1 consumer, DEBRA epoch
## reclamation) at shapes {1,2,4}p1c.
##
## Per-binary intdefines (shared with the other bench_unbounded_*
## binaries so existing CI overrides continue to work unchanged):
##   -d:UnboundedMupsicRuns          (default 3)
##   -d:UnboundedMupsicMessageCount  (default 500_000)
##   -d:BenchUnboundedWarmup         (default 2)

import std/[atomics, monotimes, options, os, parseopt, sets, strformat,
            syncio, times]
import ./bench_common
import ./adapters/lockfreequeues_unbounded_mupsic_adapter
import lockfreequeues/backoff
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
from debra import DebraManager, initDebraManager

const
  UnboundedMupsicRuns* {.intdefine.} = 3
  UnboundedMupsicMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  MaxThreads = 16

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedMupsicRuns == 3
    doAssert UnboundedMupsicMessageCount == 500_000

# ---------- UnboundedMupsic harness (N producers, 1 consumer, DEBRA) ----------

type
  UMupsicQueueT[S: static int; T; MaxT: static int] =
    Queue[T, ccMulti, ccSingle, stEager, rkEbr, 0, 0, 0, S, MaxT]

  UMupsicProducerCtx2[S: static int; T; MaxT: static int] = object
    queue: ptr UMupsicQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccSingle]
    startIdx: int
    count: int

proc umupsicProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMupsicProducerCtx2[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducer()
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      p.push(T(i))

proc runOneUMupsicRun[S: static int; T; MaxT: static int; P: static int](
    queue: ptr UMupsicQueueT[S, T, MaxT],
    manager: ptr DebraManager[MaxT, debra.ccSingle],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  var producerThreads: array[P, Thread[ptr UMupsicProducerCtx2[S, T, MaxT]]]
  var producerCtxs: array[P, UMupsicProducerCtx2[S, T, MaxT]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = UMupsicProducerCtx2[S, T, MaxT](
      queue: queue, manager: manager,
      startIdx: nextStart, count: count,
    )
    nextStart += count
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      umupsicProducerThread[S, T, MaxT],
      addr producerCtxs[i],
    )
  var local = 0
  while local < messageCount:
    let r = queue[].pop()
    if r.isSome:
      inc local
    else:
      backoffOnPeerWait()
  for i in 0 ..< P: joinThread(producerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUMupsicShape[P: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_mupsic/mpsc_unbounded/" & $P & "p1c"
  echo fmt"UnboundedMupsic {P}p1c ({slug}):"
  for _ in 0 ..< warmup:
    var a = initUnboundedMupsicAdapter[SegmentSize, uint64, MaxThreads]()
    discard runOneUMupsicRun[SegmentSize, uint64, MaxThreads, P](
      a.queue, a.manager, messageCount)
    deinitUnboundedMupsicAdapter(a)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var a = initUnboundedMupsicAdapter[SegmentSize, uint64, MaxThreads]()
    samples.add(runOneUMupsicRun[SegmentSize, uint64, MaxThreads, P](
      a.queue, a.manager, messageCount))
    deinitUnboundedMupsicAdapter(a)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Variant dispatch ----------

proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["unbounded_mupsic"]

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_mupsic":
    runUMupsicShape[1](em, UnboundedMupsicRuns, BenchUnboundedWarmup,
      UnboundedMupsicMessageCount)
    runUMupsicShape[2](em, UnboundedMupsicRuns, BenchUnboundedWarmup,
      UnboundedMupsicMessageCount)
    runUMupsicShape[4](em, UnboundedMupsicRuns, BenchUnboundedWarmup,
      UnboundedMupsicMessageCount)
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

  echo "UnboundedMupsic Throughput Benchmark"
  echo "===================================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
