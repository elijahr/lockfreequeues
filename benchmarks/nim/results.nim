## JSON results format for benchmark output.

import std/[json, times, cpuinfo]

type
  ThroughputMetrics* = object
    mean*: float
    min*: float
    max*: float
    stddev*: float

  LatencyMetrics* = object
    mean*: float
    p50*: float
    p95*: float
    p99*: float
    p999*: float
    min*: float
    max*: float

  BenchmarkResult* = object
    implementation*: string
    language*: string
    version*: string
    threadConfig*: string
    throughputOpsMs*: ThroughputMetrics
    latencyNs*: LatencyMetrics

  BenchmarkMetadata* = object
    timestamp*: string
    platform*: string
    cpu*: string
    cores*: int
    runner*: string

  BenchmarkInfo* = object
    name*: string
    queueType*: string
    messageCount*: int
    runs*: int

  BenchmarkOutput* = object
    metadata*: BenchmarkMetadata
    benchmark*: BenchmarkInfo
    results*: seq[BenchmarkResult]

proc getMetadata*(): BenchmarkMetadata =
  result.timestamp = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  result.platform = hostOS & " " & hostCPU
  result.cpu = "unknown"
  result.cores = countProcessors()
  result.runner = "local"

proc toJson*(m: ThroughputMetrics): JsonNode =
  %*{"mean": m.mean, "min": m.min, "max": m.max, "stddev": m.stddev}

proc toJson*(m: LatencyMetrics): JsonNode =
  %*{
    "mean": m.mean,
    "p50": m.p50,
    "p95": m.p95,
    "p99": m.p99,
    "p999": m.p999,
    "min": m.min,
    "max": m.max,
  }

proc toJson*(r: BenchmarkResult): JsonNode =
  %*{
    "implementation": r.implementation,
    "language": r.language,
    "version": r.version,
    "thread_config": r.threadConfig,
    "metrics":
      {"throughput_ops_ms": r.throughputOpsMs.toJson, "latency_ns": r.latencyNs.toJson},
  }

proc toJson*(m: BenchmarkMetadata): JsonNode =
  %*{
    "timestamp": m.timestamp,
    "platform": m.platform,
    "cpu": m.cpu,
    "cores": m.cores,
    "runner": m.runner,
  }

proc toJson*(b: BenchmarkInfo): JsonNode =
  %*{
    "name": b.name,
    "queue_type": b.queueType,
    "message_count": b.messageCount,
    "runs": b.runs,
  }

proc toJson*(o: BenchmarkOutput): JsonNode =
  var results = newJArray()
  for r in o.results:
    results.add(r.toJson)
  %*{"metadata": o.metadata.toJson, "benchmark": o.benchmark.toJson, "results": results}

proc writeResults*(output: BenchmarkOutput, filename: string) =
  let json = output.toJson
  writeFile(filename, json.pretty)
