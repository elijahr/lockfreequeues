
## Throughput benchmark: N producers, N consumers, shared queue.
## Measures ops/ms as thread count scales.

import std/[atomics, times, strformat, options]
import ./stats
import ./results
import ./adapter
import ./adapters/[lockfreequeues_sipsic, channels_adapter]
import lockfreequeues/mupmuc

const
  MessageCount = 1_000_000
  DefaultRuns = 33
  WarmupRuns = 3

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
    queue: var Q,
    numProducers: int,
    numConsumers: int,
    messageCount: int = MessageCount
): float =
  ## Returns throughput in ops/ms
  let messagesPerProducer = messageCount div numProducers
  let messagesPerConsumer = messageCount div numConsumers

  var done: Atomic[int]
  var consumed: Atomic[int]
  done.store(0)
  consumed.store(0)

  var producerThreads = newSeq[Thread[ptr ProducerContext[Q]]](numProducers)
  var consumerThreads = newSeq[Thread[ptr ConsumerContext[Q]]](numConsumers)
  var producerCtxs = newSeq[ProducerContext[Q]](numProducers)
  var consumerCtxs = newSeq[ConsumerContext[Q]](numConsumers)

  # Setup contexts
  for i in 0..<numProducers:
    producerCtxs[i] = ProducerContext[Q](
      queue: addr queue,
      startIdx: i * messagesPerProducer,
      count: messagesPerProducer,
      done: addr done
    )

  for i in 0..<numConsumers:
    consumerCtxs[i] = ConsumerContext[Q](
      queue: addr queue,
      count: messagesPerConsumer,
      consumed: addr consumed
    )

  # Start timing
  let startTime = epochTime()

  # Launch threads
  for i in 0..<numProducers:
    createThread(producerThreads[i], producer[Q], addr producerCtxs[i])
  for i in 0..<numConsumers:
    createThread(consumerThreads[i], consumer[Q], addr consumerCtxs[i])

  # Wait for completion
  for i in 0..<numProducers:
    joinThread(producerThreads[i])
  for i in 0..<numConsumers:
    joinThread(consumerThreads[i])

  let elapsed = epochTime() - startTime
  let elapsedMs = elapsed * 1000.0
  result = float(messageCount) / elapsedMs

proc benchmarkThroughput*[Q](
    initQueue: proc(): Q,
    numProducers: int,
    numConsumers: int,
    runs: int = DefaultRuns,
    warmup: int = WarmupRuns
): ThroughputMetrics =
  ## Run multiple iterations and collect statistics
  var samples: seq[float] = @[]

  # Warmup runs (discarded)
  for _ in 0..<warmup:
    var q = initQueue()
    discard runThroughputBenchmark(q, numProducers, numConsumers)

  # Actual runs
  for _ in 0..<runs:
    var q = initQueue()
    samples.add(runThroughputBenchmark(q, numProducers, numConsumers))

  ThroughputMetrics(
    mean: mean(samples),
    min: minVal(samples),
    max: maxVal(samples),
    stddev: stddev(samples)
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

proc mupmucProducer[N, P, C: static int, T](ctx: ptr MupmucProducerCtx[N, P, C, T]) {.thread.} =
  let producer = ctx.queue[].getProducer(idx = ctx.producerIdx)
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while not producer.push(i):
      discard

proc mupmucConsumer[N, P, C: static int, T](ctx: ptr MupmucConsumerCtx[N, P, C, T]) {.thread.} =
  let consumer = ctx.queue[].getConsumer(idx = ctx.consumerIdx)
  var local = 0
  while local < ctx.count:
    let item = consumer.pop()
    if item.isSome:
      inc local

proc runMupmucBenchmark[N, P, C: static int, T](
    queue: var Mupmuc[N, P, C, T],
    messageCount: int = MessageCount
): float =
  ## Run Mupmuc throughput benchmark with P producers and C consumers
  let messagesPerProducer = messageCount div P
  let messagesPerConsumer = messageCount div C

  var producerThreads: array[P, Thread[ptr MupmucProducerCtx[N, P, C, T]]]
  var consumerThreads: array[C, Thread[ptr MupmucConsumerCtx[N, P, C, T]]]
  var producerCtxs: array[P, MupmucProducerCtx[N, P, C, T]]
  var consumerCtxs: array[C, MupmucConsumerCtx[N, P, C, T]]

  # Setup contexts
  for i in 0..<P:
    producerCtxs[i] = MupmucProducerCtx[N, P, C, T](
      queue: addr queue,
      producerIdx: i,
      startIdx: i * messagesPerProducer,
      count: messagesPerProducer
    )

  for i in 0..<C:
    consumerCtxs[i] = MupmucConsumerCtx[N, P, C, T](
      queue: addr queue,
      consumerIdx: i,
      count: messagesPerConsumer
    )

  # Start timing
  let startTime = epochTime()

  # Launch threads
  for i in 0..<P:
    createThread(producerThreads[i], mupmucProducer[N, P, C, T], addr producerCtxs[i])
  for i in 0..<C:
    createThread(consumerThreads[i], mupmucConsumer[N, P, C, T], addr consumerCtxs[i])

  # Wait for completion
  for i in 0..<P:
    joinThread(producerThreads[i])
  for i in 0..<C:
    joinThread(consumerThreads[i])

  let elapsed = epochTime() - startTime
  let elapsedMs = elapsed * 1000.0
  result = float(messageCount) / elapsedMs

# Fixed-size Mupmuc benchmark functions for common thread counts
proc benchmarkMupmuc1P1C*(runs: int = DefaultRuns, warmup: int = WarmupRuns): ThroughputMetrics =
  var samples: seq[float] = @[]
  for _ in 0..<warmup:
    var q = initMupmuc[1024, 1, 1, int]()
    discard runMupmucBenchmark(q)
  for _ in 0..<runs:
    var q = initMupmuc[1024, 1, 1, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(mean: mean(samples), min: minVal(samples), max: maxVal(samples), stddev: stddev(samples))

proc benchmarkMupmuc2P2C*(runs: int = DefaultRuns, warmup: int = WarmupRuns): ThroughputMetrics =
  var samples: seq[float] = @[]
  for _ in 0..<warmup:
    var q = initMupmuc[1024, 2, 2, int]()
    discard runMupmucBenchmark(q)
  for _ in 0..<runs:
    var q = initMupmuc[1024, 2, 2, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(mean: mean(samples), min: minVal(samples), max: maxVal(samples), stddev: stddev(samples))

proc benchmarkMupmuc4P4C*(runs: int = DefaultRuns, warmup: int = WarmupRuns): ThroughputMetrics =
  var samples: seq[float] = @[]
  for _ in 0..<warmup:
    var q = initMupmuc[1024, 4, 4, int]()
    discard runMupmucBenchmark(q)
  for _ in 0..<runs:
    var q = initMupmuc[1024, 4, 4, int]()
    samples.add(runMupmucBenchmark(q))
  ThroughputMetrics(mean: mean(samples), min: minVal(samples), max: maxVal(samples), stddev: stddev(samples))

when isMainModule:
  echo "Throughput Benchmark"
  echo "===================="
  echo ""

  # Bounded SPSC (1P/1C only)
  echo "Sipsic (bounded SPSC) 1P/1C:"
  let sipsicMetrics = benchmarkThroughput(
    proc(): SipsicAdapter[1024, int] = initSipsicAdapter[1024, int](),
    numProducers = 1,
    numConsumers = 1,
    runs = 10
  )
  echo fmt"  mean: {sipsicMetrics.mean:.0f} ops/ms"
  echo fmt"  stddev: {sipsicMetrics.stddev:.0f}"
  echo ""

  # Mupmuc (bounded MPMC)
  for threads in [1, 2, 4]:
    echo fmt"Mupmuc (bounded MPMC) {threads}P/{threads}C:"
    let metrics = case threads
      of 1: benchmarkMupmuc1P1C(runs = 10)
      of 2: benchmarkMupmuc2P2C(runs = 10)
      of 4: benchmarkMupmuc4P4C(runs = 10)
      else: ThroughputMetrics()
    echo fmt"  mean: {metrics.mean:.0f} ops/ms"
    echo fmt"  stddev: {metrics.stddev:.0f}"
    echo ""

  # Channels (MPMC)
  for threads in [1, 2, 4]:
    echo fmt"Channels (MPMC) {threads}P/{threads}C:"
    let metrics = benchmarkThroughput(
      proc(): ChannelsAdapter[int] = initChannelsAdapter[int](1024),
      numProducers = threads,
      numConsumers = threads,
      runs = 10
    )
    echo fmt"  mean: {metrics.mean:.0f} ops/ms"
    echo fmt"  stddev: {metrics.stddev:.0f}"
    echo ""
