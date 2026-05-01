## Throughput benchmark: N producers, N consumers, shared queue.
## Measures ops/ms as thread count scales.
##
## Task 0.10 (PR 0) — this binary now natively emits Bencher Metric Format
## (BMF) JSON when invoked with `--bmf-out=<path>`. Stdout text output is
## preserved verbatim for backward compatibility with the existing
## positional CLI (`bench_throughput sipsic mupmuc unbounded_mupsic
## channels`). The BMF output replaces the legacy `bmf_adapter.py` regex
## parser that consumed the stdout text.

import std/[atomics, times, monotimes, parseopt, strformat, options, os, sets,
            syncio]
import ./stats
import ./results
import ./adapter
import
  ./adapters/[
    lockfreequeues_sipsic_adapter, channels_adapter,
    lockfreequeues_unbounded_mupsic_adapter,
  ]
import lockfreequeues/mupmuc
import lockfreequeues/unbounded_mupsic
import lockfreequeues/backoff
import debra
# Selective import of the bench_common BMF surface. PR 0 keeps the
# bespoke topology-aware harness procs below (legacy `runThroughputBenchmark`,
# `runMupmucBenchmark`, `runUnboundedMupsicBenchmark`) since they handle
# per-thread Producer/Consumer registration and DEBRA epoch boundaries
# that the generic `runThroughputHarness` does not yet support. The
# `runThroughputHarness` consolidation across all topologies is scoped
# for PR 1+ once each adapter exposes the registration surface uniformly.
# Avoid importing `ThroughputMetrics` from bench_common — it would shadow
# the legacy `results.ThroughputMetrics` already used here.
from ./bench_common import BMFEmitter, initBMFEmitter, addMeasure, emit

# All run-shape constants below are `{.intdefine.}` so they can be overridden
# at compile time without touching the source. Default behavior (no `-d:` flags)
# is unchanged: 1M messages, 33 timed runs, 3 warmup runs for the unbounded
# Mupsic harness. For tighter wall-clock budgets in CI gate runs, override via
# e.g. `nim c -d:MessageCount=100000 -d:UnboundedMupsicRuns=11 ...`.
const
  MessageCount {.intdefine.} = 1_000_000
  DefaultRuns {.intdefine.} = 33
  WarmupRuns {.intdefine.} = 3

type
  ProducerContext[Q] = object
    queue: ptr Q
    startIdx: int
    count: int
    done: ptr Atomic[int]

  ConsumerContext[Q] = object
    queue: ptr Q
    count: int
    consumed: ptr Atomic[int]

proc producer[Q](ctx: ptr ProducerContext[Q]) {.thread.} =
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while ctx.queue[].push(i) == prFull:
      discard
  ctx.done[].atomicInc()

proc consumer[Q](ctx: ptr ConsumerContext[Q]) {.thread.} =
  var local = 0
  while local < ctx.count:
    let item = ctx.queue[].pop()
    if item.success:
      inc local
  discard ctx.consumed[].fetchAdd(local)

proc runThroughputBenchmark*[Q](
    queue: var Q, numProducers: int, numConsumers: int, messageCount: int = MessageCount
): float =
  ## Returns throughput in ops/ms
  ##
  ## Message distribution must satisfy two invariants for the run to terminate:
  ##   1. sum(producer.count for producer) == messageCount
  ##   2. sum(consumer.count for consumer) == messageCount
  ## A naive `messageCount div N` truncates and breaks both when `messageCount`
  ## is not divisible by `numProducers` or `numConsumers`, which deadlocks the
  ## consumers (they wait for items the producers never enqueue) or leaves
  ## items stranded in the queue (consumers stop early). Spread the
  ## remainder over the first `messageCount mod N` workers so totals match
  ## exactly for any (P, C, messageCount) triple — including P != C.
  let baseP = messageCount div numProducers
  let remP = messageCount mod numProducers
  let baseC = messageCount div numConsumers
  let remC = messageCount mod numConsumers

  var done: Atomic[int]
  var consumed: Atomic[int]
  done.store(0)
  consumed.store(0)

  var producerThreads = newSeq[Thread[ptr ProducerContext[Q]]](numProducers)
  var consumerThreads = newSeq[Thread[ptr ConsumerContext[Q]]](numConsumers)
  var producerCtxs = newSeq[ProducerContext[Q]](numProducers)
  var consumerCtxs = newSeq[ConsumerContext[Q]](numConsumers)

  # Setup contexts. `startIdx` walks through the global id space so producer
  # ranges remain disjoint even when the per-producer count is not uniform.
  var nextStart = 0
  for i in 0 ..< numProducers:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = ProducerContext[Q](
      queue: addr queue,
      startIdx: nextStart,
      count: count,
      done: addr done,
    )
    nextStart += count

  for i in 0 ..< numConsumers:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = ConsumerContext[Q](
      queue: addr queue, count: count, consumed: addr consumed
    )

  # Start timing. Monotonic clock — `epochTime` (wall clock) can step
  # backward across NTP adjustments and skew throughput numbers.
  # Nanosecond precision: ms-precision buckets multiple short runs into
  # the same integer ms, producing identical samples and stddev=0 on a
  # fast CI runner. ops/ms is reconstructed as a float at print time.
  let startTime = getMonoTime()

  # Launch threads
  for i in 0 ..< numProducers:
    createThread(producerThreads[i], producer[Q], addr producerCtxs[i])
  for i in 0 ..< numConsumers:
    createThread(consumerThreads[i], consumer[Q], addr consumerCtxs[i])

  # Wait for completion
  for i in 0 ..< numProducers:
    joinThread(producerThreads[i])
  for i in 0 ..< numConsumers:
    joinThread(consumerThreads[i])

  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc benchmarkThroughput*[Q](
    initQueue: proc(): Q,
    numProducers: int,
    numConsumers: int,
    runs: int = DefaultRuns,
    warmup: int = WarmupRuns,
): ThroughputMetrics =
  ## Run multiple iterations and collect statistics
  var samples: seq[float] = @[]

  # Warmup runs (discarded)
  for _ in 0 ..< warmup:
    var q = initQueue()
    discard runThroughputBenchmark(q, numProducers, numConsumers)

  # Actual runs
  for _ in 0 ..< runs:
    var q = initQueue()
    samples.add(runThroughputBenchmark(q, numProducers, numConsumers))

  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples),
  )

# Mupmuc-specific benchmark types and procs
# Mupmuc requires per-thread Producer/Consumer allocation via getProducer/getConsumer

type
  MupmucProducerCtx[N, P, C: static int, T] = object
    queue: ptr Mupmuc[N, P, C, T]
    producerIdx: int
    startIdx: int
    count: int

  MupmucConsumerCtx[N, P, C: static int, T] = object
    queue: ptr Mupmuc[N, P, C, T]
    consumerIdx: int
    count: int

proc mupmucProducer[N, P, C: static int, T](
    ctx: ptr MupmucProducerCtx[N, P, C, T]
) {.thread.} =
  let producer = ctx.queue[].getProducer(idx = ctx.producerIdx)
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not producer.push(i):
      backoffOnPeerWait()

proc mupmucConsumer[N, P, C: static int, T](
    ctx: ptr MupmucConsumerCtx[N, P, C, T]
) {.thread.} =
  let consumer = ctx.queue[].getConsumer(idx = ctx.consumerIdx)
  var local = 0
  while local < ctx.count:
    let item = consumer.pop()
    if item.isSome:
      inc local

proc runMupmucBenchmark[N, P, C: static int, T](
    queue: var Mupmuc[N, P, C, T], messageCount: int = MessageCount
): float =
  ## Run Mupmuc throughput benchmark with P producers and C consumers.
  ##
  ## Distribution invariants are the same as runThroughputBenchmark: the
  ## per-producer and per-consumer counts must sum to messageCount or the
  ## consumers wait forever / producers leak items. Spread `messageCount
  ## mod P` and `messageCount mod C` over the first workers to keep the
  ## totals exact for any (P, C, messageCount) — including P != C and
  ## non-power-of-two messageCount values.
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C

  var producerThreads: array[P, Thread[ptr MupmucProducerCtx[N, P, C, T]]]
  var consumerThreads: array[C, Thread[ptr MupmucConsumerCtx[N, P, C, T]]]
  var producerCtxs: array[P, MupmucProducerCtx[N, P, C, T]]
  var consumerCtxs: array[C, MupmucConsumerCtx[N, P, C, T]]

  # Setup contexts. `startIdx` walks through the global id space so producer
  # ranges stay disjoint when the per-producer count is not uniform.
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = MupmucProducerCtx[N, P, C, T](
      queue: addr queue,
      producerIdx: i,
      startIdx: nextStart,
      count: count,
    )
    nextStart += count

  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = MupmucConsumerCtx[N, P, C, T](
      queue: addr queue, consumerIdx: i, count: count
    )

  # Start timing. Monotonic clock — `epochTime` (wall clock) can step
  # backward across NTP adjustments and skew throughput numbers.
  # See runThroughputBenchmark for the nanosecond-precision rationale.
  let startTime = getMonoTime()

  # Launch threads
  for i in 0 ..< P:
    createThread(producerThreads[i], mupmucProducer[N, P, C, T], addr producerCtxs[i])
  for i in 0 ..< C:
    createThread(consumerThreads[i], mupmucConsumer[N, P, C, T], addr consumerCtxs[i])

  # Wait for completion
  for i in 0 ..< P:
    joinThread(producerThreads[i])
  for i in 0 ..< C:
    joinThread(consumerThreads[i])

  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  result = float(messageCount) * 1_000_000.0 / elapsedNs

# Fixed-size Mupmuc benchmark functions for common thread counts
proc benchmarkMupmuc1P1C*(
    runs: int = DefaultRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  var samples: seq[float] = @[]
  for _ in 0 ..< warmup:
    var q = initMupmuc[1024, 1, 1, int]()
    discard runMupmucBenchmark(q)
  for _ in 0 ..< runs:
    var q = initMupmuc[1024, 1, 1, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples),
  )

proc benchmarkMupmuc2P2C*(
    runs: int = DefaultRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  var samples: seq[float] = @[]
  for _ in 0 ..< warmup:
    var q = initMupmuc[1024, 2, 2, int]()
    discard runMupmucBenchmark(q)
  for _ in 0 ..< runs:
    var q = initMupmuc[1024, 2, 2, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples),
  )

proc benchmarkMupmuc4P4C*(
    runs: int = DefaultRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  var samples: seq[float] = @[]
  for _ in 0 ..< warmup:
    var q = initMupmuc[1024, 4, 4, int]()
    discard runMupmucBenchmark(q)
  for _ in 0 ..< runs:
    var q = initMupmuc[1024, 4, 4, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples),
  )

proc benchmarkMupmuc8P8C*(
    runs: int = DefaultRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  ## 8P/8C is the explicit oversubscription case the CAS-retry backoff
  ## livelock fix targeted (issue #15). Kept as a fixed-static-int wrapper
  ## like 1/2/4 so the topology iteration in `isMainModule` stays
  ## table-driven without runtime generic instantiation.
  var samples: seq[float] = @[]
  for _ in 0 ..< warmup:
    var q = initMupmuc[1024, 8, 8, int]()
    discard runMupmucBenchmark(q)
  for _ in 0 ..< runs:
    var q = initMupmuc[1024, 8, 8, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples),
  )

# UnboundedMupsic-specific benchmark types and procs.
#
# UnboundedMupsic is multi-producer, single-consumer with linked-segment
# storage and DEBRA epoch-based reclamation. Producers must register a
# per-thread ThreadHandle on their own thread and obtain a Producer via
# getProducer; the consumer is implicit (a single thread driving pop on
# the queue object directly).
#
# Run count for these variants is fixed at the followup-doc value below
# (UnboundedMupsicRuns); the existing Mupmuc / Sipsic / Channels variants
# keep their previous run counts.

const
  UnboundedMupsicRuns {.intdefine.} = 33
  UnboundedMupsicSegmentSize {.intdefine.} = 64
  UnboundedMupsicMaxThreads {.intdefine.} = 8
    ## Headroom for the consumer + up to 4 producers + DEBRA bookkeeping.
  # Override separately to keep CI runs tractable; unbounded_mupsic is super-linear in message count vs bounded variants.
  UnboundedMupsicMessageCount {.intdefine.} = MessageCount

type
  UMupsicProducerCtx[S: static int, T; MaxThreads: static int] = object
    queue: ptr UnboundedMupsic[S, T, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    startIdx: int
    count: int
    done: ptr Atomic[int]

  UMupsicConsumerCtx[S: static int, T; MaxThreads: static int] = object
    queue: ptr UnboundedMupsic[S, T, MaxThreads]
    count: int
    consumed: ptr Atomic[int]

proc uMupsicProducer[S: static int, T; MaxThreads: static int](
    ctx: ptr UMupsicProducerCtx[S, T, MaxThreads]
) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(handle)
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      p.push(i)
    discard ctx.done[].fetchAdd(1)

proc uMupsicConsumer[S: static int, T; MaxThreads: static int](
    ctx: ptr UMupsicConsumerCtx[S, T, MaxThreads]
) {.thread.} =
  {.cast(gcsafe).}:
    var local = 0
    while local < ctx.count:
      let item = ctx.queue[].pop()
      if item.isSome:
        inc local
    discard ctx.consumed[].fetchAdd(local)

proc runUnboundedMupsicBenchmark[S: static int, T; MaxThreads: static int](
    adapter: var UnboundedMupsicAdapter[S, T, MaxThreads],
    numProducers: int,
    messageCount: int = MessageCount,
): float =
  ## Spawn `numProducers` producers and one consumer. Each producer
  ## pushes a disjoint range; the consumer pops until it has seen exactly
  ## `messageCount` items. Returns throughput in ops/ms.
  ##
  ## Spread `messageCount mod numProducers` over the first producers so the
  ## sum of per-producer counts equals `messageCount` exactly — without
  ## this, the harness silently degrades to fewer ops than it reports
  ## (and the ops/ms denominator becomes inconsistent across NP values
  ## when messageCount is not divisible by numProducers).
  let basePerProducer = messageCount div numProducers
  let remProducers = messageCount mod numProducers

  var done: Atomic[int]
  var consumed: Atomic[int]
  done.store(0)
  consumed.store(0)

  var producerThreads =
    newSeq[Thread[ptr UMupsicProducerCtx[S, T, MaxThreads]]](numProducers)
  var producerCtxs = newSeq[UMupsicProducerCtx[S, T, MaxThreads]](numProducers)
  var consumerThread: Thread[ptr UMupsicConsumerCtx[S, T, MaxThreads]]
  var consumerCtx = UMupsicConsumerCtx[S, T, MaxThreads](
    queue: adapter.queue, count: messageCount, consumed: addr consumed
  )

  var nextStart = 0
  for i in 0 ..< numProducers:
    let count = basePerProducer + (if i < remProducers: 1 else: 0)
    producerCtxs[i] = UMupsicProducerCtx[S, T, MaxThreads](
      queue: adapter.queue,
      manager: adapter.manager,
      startIdx: nextStart,
      count: count,
      done: addr done,
    )
    nextStart += count

  # Start timing. Monotonic clock; see runMupmucBenchmark for rationale.
  let startTime = getMonoTime()

  for i in 0 ..< numProducers:
    createThread(
      producerThreads[i], uMupsicProducer[S, T, MaxThreads], addr producerCtxs[i]
    )
  createThread(consumerThread, uMupsicConsumer[S, T, MaxThreads], addr consumerCtx)

  for i in 0 ..< numProducers:
    joinThread(producerThreads[i])
  joinThread(consumerThread)

  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc benchmarkUnboundedMupsicNP1C(
    numProducers: int,
    runs: int = UnboundedMupsicRuns,
    warmup: int = WarmupRuns,
    messageCount: int = UnboundedMupsicMessageCount,
): ThroughputMetrics =
  ## Helper for the fixed-thread-count wrappers below. The adapter
  ## (and therefore manager + queue) is rebuilt per run; the consumer
  ## is the calling thread for both warmup and timed runs, which keeps
  ## the consumer ThreadHandle stable across all pops in a run.
  var samples: seq[float] = @[]
  for _ in 0 ..< warmup:
    var a = initUnboundedMupsicAdapter[
      UnboundedMupsicSegmentSize, int, UnboundedMupsicMaxThreads
    ]()
    discard runUnboundedMupsicBenchmark(a, numProducers, messageCount)
    deinitUnboundedMupsicAdapter(a)
  for _ in 0 ..< runs:
    var a = initUnboundedMupsicAdapter[
      UnboundedMupsicSegmentSize, int, UnboundedMupsicMaxThreads
    ]()
    samples.add(runUnboundedMupsicBenchmark(a, numProducers, messageCount))
    deinitUnboundedMupsicAdapter(a)
  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples),
  )

proc benchmarkUnboundedMupsic1P1C*(
    runs: int = UnboundedMupsicRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  benchmarkUnboundedMupsicNP1C(1, runs, warmup, UnboundedMupsicMessageCount)

proc benchmarkUnboundedMupsic2P1C*(
    runs: int = UnboundedMupsicRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  benchmarkUnboundedMupsicNP1C(2, runs, warmup, UnboundedMupsicMessageCount)

proc benchmarkUnboundedMupsic4P1C*(
    runs: int = UnboundedMupsicRuns, warmup: int = WarmupRuns
): ThroughputMetrics =
  benchmarkUnboundedMupsicNP1C(4, runs, warmup, UnboundedMupsicMessageCount)

when isMainModule:
  # Unbuffer stdout so progress is visible when the bench is run under
  # a file redirect (e.g. `bench_throughput unbounded_mupsic > out.txt`).
  # Without this, block-buffering on a redirected pipe can hide all
  # output from a >20-minute variant until the process exits, which
  # makes external poll loops indistinguishable from a hang.
  setStdIoUnbuffered()

  # Per-variant run/warmup count overrides. These are `{.intdefine.}` so
  # that the `tests/t_bench_common.nim` integration test (Task 0.10) can
  # build the binary with `-d:BenchSipsicRuns=2 -d:BenchSipsicWarmup=0`
  # and finish in under 2 seconds. Production runs leave them at default.
  const
    BenchSipsicRuns {.intdefine.} = 10
    BenchSipsicWarmup {.intdefine.} = 0
    BenchMupmucRuns {.intdefine.} = 10
    BenchMupmucWarmup {.intdefine.} = 0
    BenchChannelsRuns {.intdefine.} = 10
    BenchChannelsWarmup {.intdefine.} = 0

  # CLI parsing: positional args = variant filter (legacy, preserved);
  # `--bmf-out=<path>` = native BMF emission (PR 0 Task 0.10). Unknown
  # flags or unknown positional args exit 1. Backward compatible: with
  # no args, runs everything and emits no BMF.
  const SupportedGroups = ["sipsic", "mupmuc", "unbounded_mupsic", "channels"]

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

  let supported = SupportedGroups.toHashSet
  let runGroups =
    if positional.len == 0:
      supported
    else:
      var groups = initHashSet[string]()
      for arg in positional:
        if arg notin supported:
          echo "Unknown variant group: ", arg
          echo "Supported: ", SupportedGroups
          quit 1
        groups.incl arg
      groups

  # BMF accumulator. Always allocate (cheap) so the per-variant
  # `addMeasure` calls do not need to be guarded; emit only at end if
  # `--bmf-out` was given.
  var emitter = initBMFEmitter()

  proc emitThroughputSlug(
      em: var BMFEmitter, slug: string, mean, stddev: float
  ) =
    ## Map legacy `results.ThroughputMetrics{mean, stddev}` onto the BMF
    ## triple `{value, lower_value, upper_value}` per design 2.3:
    ## value=mean, bounds = mean +/- 1*stddev (1-sigma band; matches the
    ## convention used by `bmf_adapter.py` which this code replaces).
    em.addMeasure(slug, "throughput_ops_ms", mean, mean - stddev, mean + stddev)

  echo "Throughput Benchmark"
  echo "===================="
  echo ""

  # Bounded SPSC (1P/1C only)
  if "sipsic" in runGroups:
    echo "Sipsic (bounded SPSC) 1P/1C:"
    let sipsicMetrics = benchmarkThroughput(
      proc(): SipsicAdapter[1024, int] =
        initSipsicAdapter[1024, int](),
      numProducers = 1,
      numConsumers = 1,
      runs = BenchSipsicRuns,
      warmup = BenchSipsicWarmup,
    )
    echo fmt"  mean: {sipsicMetrics.mean:.1f} ops/ms"
    echo fmt"  stddev: {sipsicMetrics.stddev:.1f}"
    echo ""
    emitter.emitThroughputSlug(
      "lockfreequeues_sipsic/spsc/1p1c",
      sipsicMetrics.mean, sipsicMetrics.stddev,
    )

  # Mupmuc (bounded MPMC). 8P/8C is the oversubscription case that
  # exercised the CAS-retry livelock (issue #15); keep it in the standard
  # iteration so any regression of the backoff fix is visible in the
  # bench output and tracked by Bencher alongside 1/2/4.
  if "mupmuc" in runGroups:
    for threads in [1, 2, 4, 8]:
      echo fmt"Mupmuc (bounded MPMC) {threads}P/{threads}C:"
      let metrics =
        case threads
        of 1:
          benchmarkMupmuc1P1C(runs = BenchMupmucRuns, warmup = BenchMupmucWarmup)
        of 2:
          benchmarkMupmuc2P2C(runs = BenchMupmucRuns, warmup = BenchMupmucWarmup)
        of 4:
          benchmarkMupmuc4P4C(runs = BenchMupmucRuns, warmup = BenchMupmucWarmup)
        of 8:
          benchmarkMupmuc8P8C(runs = BenchMupmucRuns, warmup = BenchMupmucWarmup)
        else:
          ThroughputMetrics()
      echo fmt"  mean: {metrics.mean:.1f} ops/ms"
      echo fmt"  stddev: {metrics.stddev:.1f}"
      echo ""
      emitter.emitThroughputSlug(
        fmt"lockfreequeues_mupmuc/mpmc/{threads}p{threads}c",
        metrics.mean, metrics.stddev,
      )

  # UnboundedMupsic (unbounded MPSC) — new harness, 33 runs.
  if "unbounded_mupsic" in runGroups:
    echo "==================================================="
    echo "UnboundedMupsic (unbounded MPSC) — runs = ", UnboundedMupsicRuns
    echo "==================================================="
    for producers in [1, 2, 4]:
      echo fmt"UnboundedMupsic (unbounded MPSC) {producers}P/1C:"
      let metrics =
        case producers
        of 1:
          benchmarkUnboundedMupsic1P1C()
        of 2:
          benchmarkUnboundedMupsic2P1C()
        of 4:
          benchmarkUnboundedMupsic4P1C()
        else:
          ThroughputMetrics()
      echo fmt"  mean: {metrics.mean:.1f} ops/ms"
      echo fmt"  min: {metrics.min:.1f}  max: {metrics.max:.1f}"
      echo fmt"  stddev: {metrics.stddev:.1f}"
      echo ""
      emitter.emitThroughputSlug(
        fmt"lockfreequeues_unbounded_mupsic/mpsc_unbounded/{producers}p1c",
        metrics.mean, metrics.stddev,
      )
    echo "==================================================="
    echo ""

  # Channels (MPMC). Slug uses underscore form `nim_channels` so the
  # merge_bmf.py SLUG_RE (^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*/\d+p\d+c$)
  # accepts it. The human-readable adapter `name()` ("nim/channels")
  # is only used for stdout; the slug is independent.
  if "channels" in runGroups:
    for threads in [1, 2, 4]:
      echo fmt"Channels (MPMC) {threads}P/{threads}C:"
      let metrics = benchmarkThroughput(
        proc(): ChannelsAdapter[int] =
          initChannelsAdapter[int](1024),
        numProducers = threads,
        numConsumers = threads,
        runs = BenchChannelsRuns,
        warmup = BenchChannelsWarmup,
      )
      echo fmt"  mean: {metrics.mean:.1f} ops/ms"
      echo fmt"  stddev: {metrics.stddev:.1f}"
      echo ""
      emitter.emitThroughputSlug(
        fmt"nim_channels/mpmc/{threads}p{threads}c",
        metrics.mean, metrics.stddev,
      )

  # Emit BMF JSON last so a partial run (e.g. `sipsic` only) still
  # produces a valid file with just the variants that ran.
  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
