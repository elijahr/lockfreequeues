## UnboundedMpsc throughput bench (split).
##
## Carved out of the legacy `bench_unbounded.nim` to eliminate
## cross-family iCache contention — mirrors the 37aa1c5 mitigation
## applied to `bench_mpmc.nim`. See `bench_unbounded_spsc.nim`'s
## header for the full diagnostic context.
##
## Covers UnboundedMpsc (N producers + 1 consumer, DEBRA epoch
## reclamation) at shapes {1,2,4}p1c.
##
## Per-binary intdefines (shared with the other bench_unbounded_*
## binaries so existing CI overrides continue to work unchanged):
##   -d:UnboundedMpscRuns          (default 3)
##   -d:UnboundedMpscMessageCount  (default 500_000)
##   -d:BenchUnboundedWarmup         (default 2)

import std/[atomics, monotimes, options, os, parseopt, sets, strformat,
            syncio, times]
import ./bench_common
import ./adapters/lockfreequeues_unbounded_mpsc_adapter
import lockfreequeues/backoff
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
from debra import DebraManager, initDebraManager

const
  UnboundedMpscRuns* {.intdefine.} = 3
  UnboundedMpscMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  MaxThreads = 16

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedMpscRuns == 3
    doAssert UnboundedMpscMessageCount == 500_000

# ---------- UnboundedMpsc harness (N producers, 1 consumer, DEBRA) ----------

type
  UMpscQueueT[S: static int; T; MaxT: static int] =
    Queue[T, ccMulti, ccSingle, stEager, S, MaxT]

  UMpscProducerCtx2[S: static int; T; MaxT: static int] = object
    queue: ptr UMpscQueueT[S, T, MaxT]
    manager: ptr DebraManager[MaxT, debra.ccSingle]
    startIdx: int
    count: int
    id: int
      ## Stable producer index used by -d:benchProgress logging.

when defined(benchProgress):
  # Per-10k progress prints (opt-in via -d:benchProgress) for triaging
  # intermittent CI hangs. See bench_unbounded_spsc.nim for context.
  # `benchShape` is written by `runUMpscShape` before any worker thread
  # is created and read-only thereafter, so a plain global is sufficient.
  var benchShape: string
  proc benchProgress(adapter, tag: string, n: int) =
    echo "[" & adapter & " " & benchShape & " " & tag & "=" & $n & "]"
    flushFile(stdout)

proc umpscProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMpscProducerCtx2[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducer()
    # Register this producer's debra handle on its own thread.
    p.attach()
    when defined(benchProgress):
      var pushed = 0
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      p.push(T(i))
      when defined(benchProgress):
        inc pushed
        if pushed mod 10_000 == 0:
          benchProgress("unbounded_mpsc", "p" & $ctx.id & " pushed", pushed)

proc runOneUMpscRun[S: static int; T; MaxT: static int; P: static int](
    queue: ptr UMpscQueueT[S, T, MaxT],
    manager: ptr DebraManager[MaxT, debra.ccSingle],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  var producerThreads: array[P, Thread[ptr UMpscProducerCtx2[S, T, MaxT]]]
  var producerCtxs: array[P, UMpscProducerCtx2[S, T, MaxT]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = UMpscProducerCtx2[S, T, MaxT](
      queue: queue, manager: manager,
      startIdx: nextStart, count: count, id: i,
    )
    nextStart += count
  # This (main) thread is the single consumer; register its debra handle
  # here before popping.
  queue[].attachConsumer()
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      umpscProducerThread[S, T, MaxT],
      addr producerCtxs[i],
    )
  var local = 0
  while local < messageCount:
    let r = queue[].pop()
    if r.isSome:
      inc local
      when defined(benchProgress):
        if local mod 10_000 == 0:
          benchProgress("unbounded_mpsc", "c0 popped", local)
    else:
      backoffOnPeerWait()
  for i in 0 ..< P: joinThread(producerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUMpscShape[P: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_mpsc/mpsc_unbounded/" & $P & "p1c"
  echo fmt"UnboundedMpsc {P}p1c ({slug}):"
  when defined(benchProgress):
    benchShape = $P & "p1c"
    flushFile(stdout)
  for _ in 0 ..< warmup:
    var a = initUnboundedMpscAdapter[SegmentSize, uint64, MaxThreads]()
    discard runOneUMpscRun[SegmentSize, uint64, MaxThreads, P](
      a.queue, a.manager, messageCount)
    deinitUnboundedMpscAdapter(a)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var a = initUnboundedMpscAdapter[SegmentSize, uint64, MaxThreads]()
    samples.add(runOneUMpscRun[SegmentSize, uint64, MaxThreads, P](
      a.queue, a.manager, messageCount))
    deinitUnboundedMpscAdapter(a)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Variant dispatch ----------

proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["unbounded_mpsc"]

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_mpsc":
    runUMpscShape[1](em, UnboundedMpscRuns, BenchUnboundedWarmup,
      UnboundedMpscMessageCount)
    runUMpscShape[2](em, UnboundedMpscRuns, BenchUnboundedWarmup,
      UnboundedMpscMessageCount)
    runUMpscShape[4](em, UnboundedMpscRuns, BenchUnboundedWarmup,
      UnboundedMpscMessageCount)
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

  echo "UnboundedMpsc Throughput Benchmark"
  echo "===================================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
