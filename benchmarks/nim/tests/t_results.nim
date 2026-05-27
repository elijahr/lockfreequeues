

import unittest2
import std/json
import ../results

suite "Results JSON":
  test "throughput metrics to json":
    let m = ThroughputMetrics(mean: 45000, min: 42000, max: 48000, stddev: 1200)
    let j = m.toJson
    check j["mean"].getFloat == 45000
    check j["stddev"].getFloat == 1200

  test "latency metrics to json":
    let m = LatencyMetrics(mean: 158, p50: 145, p95: 210, p99: 380, p999: 850, min: 100, max: 1000)
    let j = m.toJson
    check j["p99"].getFloat == 380
    check j["p999"].getFloat == 850

  test "benchmark result to json":
    let r = BenchmarkResult(
      implementation: "lockfreequeues/Spsc",
      language: "nim",
      version: "3.1.0",
      threadConfig: "1P/1C"
    )
    let j = r.toJson
    check j["implementation"].getStr == "lockfreequeues/Spsc"
    check j["thread_config"].getStr == "1P/1C"

  test "metadata contains cores":
    let m = getMetadata()
    check m.cores > 0
