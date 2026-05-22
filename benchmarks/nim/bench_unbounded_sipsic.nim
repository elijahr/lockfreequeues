## UnboundedSipsic throughput bench (v5.0.0 3.3.9-D split).
##
## Carved out of the legacy `bench_unbounded.nim` to eliminate
## cross-family iCache contention — mirrors the 37aa1c5 mitigation
## applied to `bench_mpmc.nim`. Before this split, the single
## `bench_unbounded` binary co-compiled UnboundedSipsic +
## UnboundedSipmuc + UnboundedMupsic + UnboundedMupmuc (plus three
## MVP adapters under MoodyCamel / Loony / Crossbeam SegQueue gates)
## into one release-mode binary. Step 3.3.9 retry #4's cold-state
## diagnostic surfaced -32% to -34% throughput regressions on
## unbounded_mupmuc/2p2c, unbounded_mupsic/2p1c, and unbounded_mupsic/
## 4p1c that pepper attributed to the same bench-binary-layout
## artifact 37aa1c5 mitigated. Isolating each unbounded family into
## its own binary removes that contention surface at the source.
##
## Covers UnboundedSipsic (no DEBRA, plain SPSC) at 1p1c.
##
## Per-binary intdefines (shared with the other bench_unbounded_*
## binaries so existing CI overrides continue to work unchanged):
##   -d:UnboundedSipsicRuns          (default 3)
##   -d:UnboundedSipsicMessageCount  (default 500_000)
##   -d:BenchUnboundedWarmup         (default 2)

import std/[monotimes, options, os, parseopt, sets, strformat,
            syncio, times]
import ./bench_common
import lockfreequeues/backoff
import lockfreequeues/unbounded_sipsic

const
  UnboundedSipsicRuns* {.intdefine.} = 3
  UnboundedSipsicMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedSipsicRuns == 3
    doAssert UnboundedSipsicMessageCount == 500_000

# ---------- UnboundedSipsic harness (no DEBRA, plain SPSC) ----------

type
  USipsicProducerCtx[S: static int; T] = object
    queue: ptr UnboundedSipsic[S, T]
    count: int

  USipsicConsumerCtx[S: static int; T] = object
    queue: ptr UnboundedSipsic[S, T]
    count: int

proc usipsicProducerThread[S: static int; T](
    ctx: ptr USipsicProducerCtx[S, T]
) {.thread.} =
  for i in 0 ..< ctx.count:
    ctx.queue[].push(T(i))

proc usipsicConsumerThread[S: static int; T](
    ctx: ptr USipsicConsumerCtx[S, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let r = ctx.queue[].pop()
    if r.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneUSipsicRun[S: static int; T](
    queue: ptr UnboundedSipsic[S, T], messageCount: int
): float =
  var producerThread: Thread[ptr USipsicProducerCtx[S, T]]
  var consumerThread: Thread[ptr USipsicConsumerCtx[S, T]]
  var producerCtx = USipsicProducerCtx[S, T](queue: queue, count: messageCount)
  var consumerCtx = USipsicConsumerCtx[S, T](queue: queue, count: messageCount)
  let startTime = getMonoTime()
  createThread(producerThread, usipsicProducerThread[S, T], addr producerCtx)
  createThread(consumerThread, usipsicConsumerThread[S, T], addr consumerCtx)
  joinThread(producerThread)
  joinThread(consumerThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUSipsicShape(em: var BMFEmitter, runs, warmup, messageCount: int) =
  let slug = "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c"
  echo fmt"UnboundedSipsic 1p1c ({slug}):"
  for _ in 0 ..< warmup:
    var q = newUnboundedSipsic[SegmentSize, uint64]()
    discard runOneUSipsicRun(addr q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = newUnboundedSipsic[SegmentSize, uint64]()
    samples.add(runOneUSipsicRun(addr q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Variant dispatch ----------

proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["unbounded_sipsic"]

const SupportedVariants = supportedVariantsList()

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_sipsic":
    runUSipsicShape(em,
      UnboundedSipsicRuns, BenchUnboundedWarmup,
      UnboundedSipsicMessageCount)
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

  echo "UnboundedSipsic Throughput Benchmark"
  echo "===================================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
