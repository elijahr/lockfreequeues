

## Main benchmark runner for all Nim queue implementations.
## Outputs JSON results to stdout or file.

import std/[json, strformat, parseopt, strutils]
import ./results
import ./stats
import ./bench_throughput
import ./bench_latency
import ./adapter
import ./adapters/[lockfreequeues_sipsic, channels_adapter]

const Version = "3.1.0"

type
  BenchConfig = object
    outputFile: string
    runs: int
    messageCount: int
    includeLatency: bool
    includeThroughput: bool
    queueTypes: seq[string]

proc parseArgs(): BenchConfig =
  result = BenchConfig(
    runs: 33,
    messageCount: 1_000_000,
    includeLatency: true,
    includeThroughput: true,
    queueTypes: @["all"]
  )

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "o", "output": result.outputFile = p.val
      of "runs": result.runs = parseInt(p.val)
      of "messages": result.messageCount = parseInt(p.val)
      of "no-latency": result.includeLatency = false
      of "no-throughput": result.includeThroughput = false
      of "queue": result.queueTypes.add(p.val)
      of "h", "help":
        echo "Usage: bench_main [options]"
        echo "  -o, --output FILE    Write JSON to file (default: stdout)"
        echo "  --runs N             Number of benchmark runs (default: 33)"
        echo "  --messages N         Messages per run (default: 1000000)"
        echo "  --no-latency         Skip latency benchmarks"
        echo "  --no-throughput      Skip throughput benchmarks"
        echo "  --queue TYPE         Specific queue to benchmark"
        quit(0)
      else: discard
    of cmdArgument: discard

proc runBenchmarks(config: BenchConfig): BenchmarkOutput =
  result.metadata = getMetadata()
  result.benchmark = BenchmarkInfo(
    name: "nim-queues",
    queueType: "all",
    messageCount: config.messageCount,
    runs: config.runs
  )

  # Bounded SPSC - Sipsic
  if config.includeThroughput:
    echo "Benchmarking Sipsic throughput (1P/1C)..."
    let throughput = benchmarkThroughput(
      proc(): SipsicAdapter[1024, int] = initSipsicAdapter[1024, int](),
      numProducers = 1,
      numConsumers = 1,
      runs = config.runs
    )
    var r = BenchmarkResult(
      implementation: "lockfreequeues/Sipsic",
      language: "nim",
      version: Version,
      threadConfig: "1P/1C",
      throughputOpsMs: throughput
    )
    if config.includeLatency:
      echo "Benchmarking Sipsic latency..."
      r.latencyNs = benchmarkLatency(
        proc(): SipsicAdapter[64, int] = initSipsicAdapter[64, int](),
        runs = config.runs
      )
    result.results.add(r)

  # Bounded MPMC - Mupmuc (multi-producer multi-consumer)
  if config.includeThroughput:
    echo "Benchmarking Mupmuc throughput (1P/1C)..."
    let mupmuc1p1c = benchmarkMupmuc1P1C(runs = config.runs)
    result.results.add(BenchmarkResult(
      implementation: "lockfreequeues/Mupmuc",
      language: "nim",
      version: Version,
      threadConfig: "1P/1C",
      throughputOpsMs: mupmuc1p1c
    ))

    echo "Benchmarking Mupmuc throughput (2P/2C)..."
    let mupmuc2p2c = benchmarkMupmuc2P2C(runs = config.runs)
    result.results.add(BenchmarkResult(
      implementation: "lockfreequeues/Mupmuc",
      language: "nim",
      version: Version,
      threadConfig: "2P/2C",
      throughputOpsMs: mupmuc2p2c
    ))

    echo "Benchmarking Mupmuc throughput (4P/4C)..."
    let mupmuc4p4c = benchmarkMupmuc4P4C(runs = config.runs)
    result.results.add(BenchmarkResult(
      implementation: "lockfreequeues/Mupmuc",
      language: "nim",
      version: Version,
      threadConfig: "4P/4C",
      throughputOpsMs: mupmuc4p4c
    ))

  # Nim Channels (bounded MPMC)
  for threads in [1, 2, 4]:
    if config.includeThroughput:
      echo fmt"Benchmarking channels throughput ({threads}P/{threads}C)..."
      let throughput = benchmarkThroughput(
        proc(): ChannelsAdapter[int] = initChannelsAdapter[int](1024),
        numProducers = threads,
        numConsumers = threads,
        runs = config.runs
      )
      result.results.add(BenchmarkResult(
        implementation: "nim/channels",
        language: "nim",
        version: NimVersion,
        threadConfig: fmt"{threads}P/{threads}C",
        throughputOpsMs: throughput
      ))

when isMainModule:
  let config = parseArgs()
  echo "Lock-Free Queue Benchmarks"
  echo "=========================="
  echo ""

  let output = runBenchmarks(config)
  let jsonOutput = output.toJson.pretty

  if config.outputFile.len > 0:
    writeFile(config.outputFile, jsonOutput)
    echo fmt"Results written to {config.outputFile}"
  else:
    echo jsonOutput
