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
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub

const
  UnboundedSipsicRuns* {.intdefine.} = 3
  UnboundedSipsicMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  SipsicMaxThreads = 4
    ## Type-uniform phantom for the sipsic-absorbed `Queue` branch.

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedSipsicRuns == 3
    doAssert UnboundedSipsicMessageCount == 500_000

# ---------- UnboundedSipsic harness (no DEBRA, plain SPSC) ----------

type
  USipsicQueue[S: static int; T] =
    Queue[T, ccSingle, ccSingle, stEager, S, SipsicMaxThreads]

  USipsicProducerCtx[S: static int; T] = object
    queue: ptr USipsicQueue[S, T]
    count: int

  USipsicConsumerCtx[S: static int; T] = object
    queue: ptr USipsicQueue[S, T]
    count: int

when defined(benchProgress):
  # Per-10k progress prints (opt-in via -d:benchProgress) for triaging
  # intermittent CI hangs in the four unbounded bench binaries. The
  # prints are compiled out when the define is absent so local-dev
  # output stays clean; CI's bench.yml passes -d:benchProgress for the
  # unbounded legs only. See the v5.0.0-wave hang-triage notes.
  proc benchProgress(adapter, shape, tag: string, n: int) =
    echo "[" & adapter & " " & shape & " " & tag & "=" & $n & "]"
    flushFile(stdout)

proc usipsicProducerThread[S: static int; T](
    ctx: ptr USipsicProducerCtx[S, T]
) {.thread.} =
  var producer = ctx.queue[].getProducer()
  for i in 0 ..< ctx.count:
    producer.push(T(i))
    when defined(benchProgress):
      if (i + 1) mod 10_000 == 0:
        benchProgress("unbounded_sipsic", "1p1c", "p0 pushed", i + 1)

proc usipsicConsumerThread[S: static int; T](
    ctx: ptr USipsicConsumerCtx[S, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let r = ctx.queue[].pop()
    if r.isSome:
      inc local
      when defined(benchProgress):
        if local mod 10_000 == 0:
          benchProgress("unbounded_sipsic", "1p1c", "c0 popped", local)
    else:
      backoffOnPeerWait()

proc runOneUSipsicRun[S: static int; T](
    queue: ptr USipsicQueue[S, T], messageCount: int
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
    var q = newUnboundedSipsicQueue[uint64, stEager, SegmentSize, SipsicMaxThreads]()
    discard runOneUSipsicRun(addr q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = newUnboundedSipsicQueue[uint64, stEager, SegmentSize, SipsicMaxThreads]()
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
