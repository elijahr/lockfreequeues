## Latency benchmark: Ping-pong between 2 threads.
## Measures RTT in nanoseconds with percentile distribution.
##
## Task 1.1 (PR 1) — exposes per-binary `{.intdefine.}` overrides for
## wall-time control: `BenchLatencyRuns` (default 33) and
## `BenchLatencyMessageCount` (default 100_000). These mirror the
## `BenchSipsicRuns` / `MessageCount` pattern in bench_throughput.nim.
## They are referenced by Task 1.2 once the binary is rewritten on top
## of `bench_common.runLatencyHarness`; until then they are public-API
## stable so downstream test/CI tasks can pin them.

import std/[atomics, times, monotimes]
import ./stats
import ./results
import ./adapter
import ./adapters/lockfreequeues_sipsic_adapter

const
  ## Per-binary intdefines for latency wall-time control. Task 1.2 wires
  ## these into the rewritten `runLatencyHarness` call site; Task 1.1
  ## only ships the symbols + defaults so the test surface lands first.
  ## NOTE: kept as `*` (exported) so external consumers (tests, CI) can
  ## reference them; legacy `DefaultIterations` / `DefaultRuns` /
  ## `WarmupRuns` remain so the existing `runLatencyBenchmark` path
  ## continues to compile until Task 1.2 deletes it.
  BenchLatencyRuns* {.intdefine.} = 33
  BenchLatencyMessageCount* {.intdefine.} = 100_000

  DefaultIterations = 100_000
  DefaultRuns = 33
  WarmupRuns = 3

# Task 1.1 compile-time test gates. These flags are set ONLY by
# `tests/t_bench_latency.nim` to assert the intdefine defaults / overrides
# at compile time; production builds never set them, so the `static`
# blocks evaluate trivially in normal use.
when defined(BenchLatencyTestCompileTime):
  static:
    doAssert BenchLatencyRuns == 33,
      "BenchLatencyRuns default must be 33 (got " & $BenchLatencyRuns & ")"
    doAssert BenchLatencyMessageCount == 100_000,
      "BenchLatencyMessageCount default must be 100_000 (got " &
      $BenchLatencyMessageCount & ")"

when defined(BenchLatencyTestCompileTimeOverrides):
  static:
    doAssert BenchLatencyRuns == 2,
      "BenchLatencyRuns override must be 2 (got " & $BenchLatencyRuns & ")"
    doAssert BenchLatencyMessageCount == 1000,
      "BenchLatencyMessageCount override must be 1000 (got " &
      $BenchLatencyMessageCount & ")"

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
