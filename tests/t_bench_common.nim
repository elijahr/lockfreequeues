## Tests for benchmarks/nim/bench_common.nim — the shared bench harness module.
##
## Task 0.1 RED test: this file must fail to compile until bench_common.nim
## exists and exports the public API surface described in the design doc
## (`/Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-design.md`
##  section 2.1). The test's only job at this stage is to reference each
## promised symbol so the compiler enforces the contract.
##
## Subsequent tasks (0.2 onward) will add behavior tests against these
## symbols.

import std/[json, os, strutils]
import unittest2
import ../benchmarks/nim/bench_common

suite "bench_common":
  test "module exports public API surface (symbol reference, compile-time only)":
    # Compile-time: reference each promised type. If any symbol is renamed
    # or deleted by future tasks, this test stops compiling. Bodies of
    # `initBMFEmitter` etc. raise `AssertionDefect` until tasks 0.2-0.6
    # land their implementations, so we MUST NOT call them here.
    when not declared(BMFEmitter): {.error: "BMFEmitter missing".}
    when not declared(Histogram): {.error: "Histogram missing".}
    when not declared(LatencyMetrics): {.error: "LatencyMetrics missing".}
    when not declared(ThroughputMetrics): {.error: "ThroughputMetrics missing".}
    when not declared(Topology): {.error: "Topology missing".}
    when not declared(MeasureValue): {.error: "MeasureValue missing".}
    when not declared(PushResult): {.error: "PushResult missing".}
    when not declared(PopResult): {.error: "PopResult missing".}

    # Reference all six Topology members so renames break here.
    let topologies = {
      tSpsc, tMpsc, tMpmc,
      tSpscUnbounded, tMpscUnbounded, tMpmcUnbounded,
    }
    check topologies.card == 6

    # Default-init the result-type objects (no stub-body call required).
    var lm: LatencyMetrics
    var tm: ThroughputMetrics
    check lm.samples == 0
    check tm.runs == 0

    # PushResult / PopResult literal references.
    let pr: PushResult = prSuccess
    check pr == prSuccess
    let pop = PopResult[uint64](success: false, value: 0'u64)
    check pop.success == false

    # Reference factories at compile time only (so stub bodies don't fire).
    when not compiles(initBMFEmitter()):
      {.error: "initBMFEmitter signature missing".}
    when not compiles(initHistogram(false)):
      {.error: "initHistogram signature missing".}

# ---------- Task 0.2: BMFEmitter behavior ----------

proc readJsonFile(path: string): JsonNode =
  parseJson(readFile(path))

suite "bench_common BMFEmitter":
  test "empty emitter writes {}":
    let path = getTempDir() / "bench_common_empty.json"
    var em = initBMFEmitter()
    em.emit(path)
    check readJsonFile(path) == newJObject()
    removeFile(path)

  test "two slugs are alpha-sorted":
    let path = getTempDir() / "bench_common_two_slugs.json"
    var em = initBMFEmitter()
    em.addMeasure("zzz_lib/spsc/1p1c", "throughput", 100.0)
    em.addMeasure("aaa_lib/spsc/1p1c", "throughput", 200.0)
    em.emit(path)
    # Read raw text to verify ordering, since JsonNode field order in Nim
    # is preserved per insertion but pretty-printed via std/json sort_keys.
    let raw = readFile(path)
    let aaaIdx = raw.find("aaa_lib")
    let zzzIdx = raw.find("zzz_lib")
    check aaaIdx >= 0
    check zzzIdx >= 0
    check aaaIdx < zzzIdx
    removeFile(path)

  test "measures within a slug are alpha-sorted":
    let path = getTempDir() / "bench_common_measures_sorted.json"
    var em = initBMFEmitter()
    em.addMeasure("foo/spsc/1p1c", "throughput", 100.0)
    em.addMeasure("foo/spsc/1p1c", "latency_p50_ns", 50.0)
    em.addMeasure("foo/spsc/1p1c", "latency_p99_ns", 90.0)
    em.emit(path)
    let raw = readFile(path)
    # latency_p50_ns < latency_p99_ns < throughput in alpha order.
    let i50 = raw.find("latency_p50_ns")
    let i99 = raw.find("latency_p99_ns")
    let it = raw.find("throughput")
    check i50 >= 0
    check i99 >= 0
    check it >= 0
    check i50 < i99
    check i99 < it
    removeFile(path)

  test "NaN bounds are omitted":
    let path = getTempDir() / "bench_common_nan_bounds.json"
    var em = initBMFEmitter()
    em.addMeasure("foo/spsc/1p1c", "throughput", 100.0)  # both bounds default NaN
    em.emit(path)
    let node = readJsonFile(path)
    let inner = node["foo/spsc/1p1c"]["throughput"]
    check inner.kind == JObject
    check "value" in inner
    check "lower_value" notin inner
    check "upper_value" notin inner
    check inner["value"].getFloat() == 100.0
    removeFile(path)

  test "finite bounds emit lower_value and upper_value":
    let path = getTempDir() / "bench_common_finite_bounds.json"
    var em = initBMFEmitter()
    em.addMeasure("foo/spsc/1p1c", "throughput", 100.0,
                  lower = 95.0, upper = 105.0)
    em.emit(path)
    let inner = readJsonFile(path)["foo/spsc/1p1c"]["throughput"]
    check inner["value"].getFloat() == 100.0
    check inner["lower_value"].getFloat() == 95.0
    check inner["upper_value"].getFloat() == 105.0
    removeFile(path)
