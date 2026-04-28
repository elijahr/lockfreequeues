

## Latency benchmark: Ping-pong between 2 threads.
## Measures RTT in nanoseconds with percentile distribution.

import std/[atomics, times, monotimes]
import ./stats
import ./results
import ./adapter
import ./adapters/lockfreequeues_sipsic

const
  DefaultIterations = 100_000
  DefaultRuns = 33
  WarmupRuns = 3

type
  PingPongContext[Q] = object
    sendQueue: ptr Q
    recvQueue: ptr Q
    iterations: int
    ready: ptr Atomic[bool]

proc pongProc[Q](ctx: ptr PingPongContext[Q]) {.thread.} =
  ctx.ready[].store(true, moRelease)

  for _ in 0..<ctx.iterations:
    # Wait for ping
    while true:
      let item = ctx.recvQueue[].pop()
      if item.success:
        break
    # Send pong
    while ctx.sendQueue[].push(1) == prFull:
      discard

proc runLatencyBenchmark*[Q](
    initQueue: proc(): Q,
    iterations: int = DefaultIterations
): seq[float] =
  ## Returns array of RTT samples in nanoseconds
  var sendQ = initQueue()
  var recvQ = initQueue()
  var ready: Atomic[bool]
  ready.store(false)

  var samples = newSeq[float](iterations)

  var pongCtx = PingPongContext[Q](
    sendQueue: addr recvQ,  # Reversed for pong
    recvQueue: addr sendQ,
    iterations: iterations,
    ready: addr ready
  )

  # Start pong thread
  var pongThread: Thread[ptr PingPongContext[Q]]
  createThread(pongThread, pongProc[Q], addr pongCtx)

  # Wait for pong ready
  while not ready.load(moAcquire):
    discard

  for i in 0..<iterations:
    let startTime = getMonoTime()

    # Send ping
    while sendQ.push(1) == prFull:
      discard
    # Wait for pong
    while true:
      let item = recvQ.pop()
      if item.success:
        break

    let endTime = getMonoTime()
    samples[i] = float(inNanoseconds(endTime - startTime))

  joinThread(pongThread)
  samples

proc benchmarkLatency*[Q](
    initQueue: proc(): Q,
    iterations: int = DefaultIterations,
    runs: int = DefaultRuns,
    warmup: int = WarmupRuns
): LatencyMetrics =
  ## Run multiple iterations and collect percentile statistics
  var allSamples: seq[float] = @[]

  # Warmup
  for _ in 0..<warmup:
    discard runLatencyBenchmark(initQueue, iterations div 10)

  # Actual runs - collect all samples
  for _ in 0..<runs:
    let samples = runLatencyBenchmark(initQueue, iterations)
    allSamples.add(samples)

  LatencyMetrics(
    mean: mean(allSamples),
    p50: percentile(allSamples, 0.50),
    p95: percentile(allSamples, 0.95),
    p99: percentile(allSamples, 0.99),
    p999: percentile(allSamples, 0.999),
    min: minVal(allSamples),
    max: maxVal(allSamples)
  )

when isMainModule:
  import std/strformat

  echo "Latency Benchmark (ping-pong RTT)"
  echo "=================================="
  echo ""

  echo "Sipsic (bounded SPSC):"
  let metrics = benchmarkLatency(
    proc(): SipsicAdapter[64, int] = initSipsicAdapter[64, int](),
    iterations = 10_000,
    runs = 5
  )
  echo fmt"  mean: {metrics.mean:.0f} ns"
  echo fmt"  p50:  {metrics.p50:.0f} ns"
  echo fmt"  p95:  {metrics.p95:.0f} ns"
  echo fmt"  p99:  {metrics.p99:.0f} ns"
  echo fmt"  p999: {metrics.p999:.0f} ns"
  echo fmt"  min:  {metrics.min:.0f} ns"
  echo fmt"  max:  {metrics.max:.0f} ns"
