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

# ---------- Task 02 (v4.3): HarnessBackoff env-var toggle ----------

suite "bench_common HarnessBackoff toggle":
  test "disableHarnessBackoff defaults to false when LFQ_BENCH_HARNESS_BACKOFF unset":
    # The toggle is cached at module init via a top-level `let` binding.
    # Default behavior (env var unset or "1") must be `false` so the
    # harness's spin-then-yield backoff stays active for normal runs.
    # Toggle-active case (env="0" -> true) is exercised out-of-process
    # by the `benchToggleSmoke` nimble task; in-process `putEnv` after
    # import would not re-evaluate the cached binding.
    check disableHarnessBackoff == false

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

# ---------- Task 0.4: Stats helpers ----------

suite "bench_common Stats":
  test "mean of integer-like floats":
    check mean(@[1.0, 2.0, 3.0, 4.0]) == 2.5

  test "mean of empty data is 0.0 (defined behavior)":
    check mean(newSeq[float]()) == 0.0

  test "stddev of [1,2,3,4] matches numpy's sample stddev":
    # numpy default ddof=1 (sample): sqrt(sum((x-mean)^2) / (n-1)) = sqrt(5/3)
    let s = stddev(@[1.0, 2.0, 3.0, 4.0])
    let expected = 1.2909944487358056  # sqrt(5/3)
    check abs(s - expected) < 1e-9

  test "stddev of singleton is 0":
    check stddev(@[42.0]) == 0.0

  test "minVal and maxVal":
    check minVal(@[3.0, 1.0, 4.0, 1.5, 5.0, 9.0]) == 1.0
    check maxVal(@[3.0, 1.0, 4.0, 1.5, 5.0, 9.0]) == 9.0

  test "percentile(0..99, 0.5) is 49.5 (linear interpolation)":
    var data: seq[float]
    for i in 0 .. 99: data.add(float(i))
    # Linear interpolation: index = 0.5 * 99 = 49.5; data[49] + 0.5 * (data[50]-data[49]) = 49.5
    check abs(percentile(data, 0.5) - 49.5) < 1e-9

  test "percentile(p=0.0) is min, percentile(p=1.0) is max":
    var data: seq[float]
    for i in 0 .. 99: data.add(float(i))
    check percentile(data, 0.0) == 0.0
    check percentile(data, 1.0) == 99.0

# ---------- Task 0.3: Histogram ----------

import std/[math, random]

proc generateLogNormal(n: int, seed: int64): seq[float] =
  ## Deterministic log-normal-ish samples. We use exp(N(0,1)) modeled
  ## via Box-Muller from a seeded RNG so the test is reproducible.
  var r = initRand(seed)
  result = newSeq[float](n)
  var i = 0
  while i < n:
    # Box-Muller: two uniforms -> two standard normals.
    let u1 = r.rand(1.0)
    let u2 = r.rand(1.0)
    if u1 == 0.0: continue
    let mag = sqrt(-2.0 * ln(u1))
    let z0 = mag * cos(2.0 * PI * u2)
    let z1 = mag * sin(2.0 * PI * u2)
    result[i] = exp(z0)
    if i + 1 < n: result[i + 1] = exp(z1)
    i += 2

suite "bench_common Histogram":
  test "percentile(1.0) equals top-K max":
    var h = initHistogram()
    for v in [1.0, 5.0, 3.0, 99.0, 7.0, 42.0]:
      h.record(v)
    check h.percentile(1.0) == 99.0

  test "p99 within 1% of sort fallback on 100K log-normal samples":
    let samples = generateLogNormal(100_000, 0xC0FFEE'i64)
    let exact = percentile(samples, 0.99)
    var h = initHistogram()
    for v in samples: h.record(v)
    let approx = h.percentile(0.99)
    let relErr = abs(approx - exact) / exact
    check relErr < 0.01

  test "p50 reads from reservoir and is close to sort-fallback":
    let samples = generateLogNormal(100_000, 0xBEEF'i64)
    let exact = percentile(samples, 0.50)
    var h = initHistogram()
    for v in samples: h.record(v)
    let approx = h.percentile(0.50)
    # Reservoir is a uniform sample of 99K of 100K — within 5% on a
    # well-behaved log-normal.
    let relErr = abs(approx - exact) / exact
    check relErr < 0.05

  test "debug mode returns exact sort answer":
    var h = initHistogram(debug = true)
    for v in [1.0, 5.0, 3.0, 99.0, 7.0, 42.0]:
      h.record(v)
    # Sorted: [1, 3, 5, 7, 42, 99]; len 6. percentile(0.99) on [..]:
    # linear interp index = 0.99 * 5 = 4.95
    # data[4] + 0.95 * (data[5]-data[4]) = 42 + 0.95 * 57 = 42 + 54.15 = 96.15
    check abs(h.percentile(0.99) - 96.15) < 1e-9

  test "topK of small sample returns sorted ascending":
    var h = initHistogram()
    for v in [9.0, 1.0, 5.0, 3.0, 7.0]:
      h.record(v)
    check h.topK() == @[1.0, 3.0, 5.0, 7.0, 9.0]

  # ---------- Task 6.2: HistogramTopK sized to scale with overrides ----------
  #
  # `runLatencyHarness` builds a fresh Histogram per run and averages
  # per-run percentiles (design 2.5); each histogram only sees
  # `BenchLatencyMessageCount` samples, NOT messageCount * runCount.
  # At the default MessageCount=100,000 a single histogram captures
  # every sample exactly (TopK=5000 + Reservoir=99,000 ≥ 100,000), so
  # K=1000 would already have been enough for the default config.
  # The K=5000 sizing is anticipatory: an operator who bumps
  # BenchLatencyMessageCount to ~5M (uncommon, but a future stress
  # configuration) needs ~5000 in the exact top-K stratum to keep
  # p999 (tail count = MessageCount * 0.001) outside the rescaled
  # reservoir.
  test "HistogramTopK is at least 5000 (anticipates MessageCount up to ~5M)":
    check HistogramTopK >= 5000

  when defined(BenchCommonStress):
    test "p999 within 5% of sort fallback at 3.3M-sample stress shape":
      # Stress-test the K=5000 design choice at a single-histogram
      # volume that an operator could reach by overriding
      # BenchLatencyMessageCount upward. At seenAll=3.3M the p999 tail
      # count is 3300 and lies inside the K=5000 exact top-K stratum,
      # so percentile(0.999) is read from the exact top-K heap.
      # Tolerance is 5% per impl plan acceptance criterion. The test
      # allocates a 3.3M-sample seq and runs `record()` that many
      # times, so it is gated behind `-d:BenchCommonStress` to keep
      # the default `nimble benchtests` invocation under ~1 second.
      # Run explicitly as `nimble benchtestsstress` (or
      # `nim c -d:BenchCommonStress -r tests/t_bench_common`).
      let samples = generateLogNormal(3_300_000, 0xDEADBEEF'i64)
      let exact = percentile(samples, 0.999)
      var h = initHistogram()
      for v in samples: h.record(v)
      let approx = h.percentile(0.999)
      let relErr = abs(approx - exact) / exact
      check relErr < 0.05

# ---------- Task 0.5: runThroughputHarness smoke ----------

# Tiny inline adapter that satisfies bench_common's BenchAdapter shape
# (push -> PushResult, pop -> PopResult[uint64]). Lives in this test
# file because Task 0.9 has not yet reconciled benchmarks/nim/adapter.nim
# (legacy) with bench_common (new); once that lands, this shim moves
# to a real adapter file.
#
# Wraps lockfreequeues' Sipsic (SPSC bounded). The smoke is 1P/1C in
# all uses (throughput queue, latency fwd, latency rev), so SPSC fits.
# Replaces an earlier `Channel[uint64]` shim whose stdlib `tryRecv`
# read `q.mask` without holding the mutex while `rawSend` wrote it
# under the mutex — a real C++ memory-model data race that TSAN
# flagged (3 instances, one per SmokeAdapter).

import lockfreequeues
import options

# N=1024 covers every smoke caller (all pass capacity=1024). With
# 1P/1C backpressure, in-flight depth never exceeds N regardless of
# total messageCount.
const SmokeAdapterCapacity = 1024

type SmokeAdapter = object
  queue: Sipsic[SmokeAdapterCapacity, uint64]

proc initSmokeAdapter(capacity: int): SmokeAdapter =
  doAssert capacity <= SmokeAdapterCapacity,
    "SmokeAdapter capacity " & $capacity & " exceeds compile-time " &
    $SmokeAdapterCapacity
  result.queue = initSipsic[SmokeAdapterCapacity, uint64]()

proc push(a: var SmokeAdapter, v: uint64): PushResult =
  if a.queue.push(v): prSuccess else: prFull

proc pop(a: var SmokeAdapter): PopResult[uint64] =
  let item = a.queue.pop()
  if item.isSome:
    PopResult[uint64](success: true, value: item.get)
  else:
    PopResult[uint64](success: false, value: 0'u64)

suite "bench_common runThroughputHarness":
  test "smoke: 1P/1C, 1000 messages, 1 run, 0 warmup completes":
    let metrics = runThroughputHarness[SmokeAdapter](
      queueInit = proc(cap: int): SmokeAdapter = initSmokeAdapter(cap),
      capacity = 1024,
      numProducers = 1,
      numConsumers = 1,
      messageCount = 1000,
      runCount = 1,
      warmupCount = 0,
    )
    check metrics.runs == 1
    check metrics.ops_ms_mean > 0.0

# ---------- Task 0.6: runLatencyHarness smoke ----------

suite "bench_common runLatencyHarness":
  test "smoke: 1P/1C, 1000 messages, 1 run, 0 warmup; p50<p99<max":
    let metrics = runLatencyHarness[SmokeAdapter](
      queueInit = proc(): SmokeAdapter = initSmokeAdapter(1024),
      messageCount = 1000,
      runCount = 1,
      warmupCount = 0,
    )
    # At messageCount=1000 < HistogramTopK=5000 every sample lands in topK,
    # so the channel-drained sample count must equal the input exactly.
    # Catches drain-protocol counter-ordering bugs (e.g. wire-swap of
    # seenAll vs topKLen) that pass a >= bound but differ from input.
    check metrics.samples == 1000
    check metrics.p50_ns > 0.0
    check metrics.p99_ns >= metrics.p50_ns
    check metrics.max_ns >= metrics.p99_ns

  test "smoke: 1P/1C, 5100 messages exercises reservoir drain branch":
    # messageCount > HistogramTopK (5000) so ~100 samples flow through
    # reservoirAdmit. Catches drain-protocol bugs that the small-volume
    # smoke (1000 samples, all in topK) cannot exercise.
    let metrics = runLatencyHarness[SmokeAdapter](
      queueInit = proc(): SmokeAdapter = initSmokeAdapter(1024),
      messageCount = 5100,
      runCount = 1,
      warmupCount = 0,
    )
    check metrics.samples == 5100
    check metrics.p50_ns > 0.0
    check metrics.p99_ns >= metrics.p50_ns
    check metrics.max_ns >= metrics.p99_ns

# ---------- Task 0.8: lockfreequeues adapter smoke tests ----------

import std/sets
import ../benchmarks/nim/adapters/lockfreequeues_sipmuc_adapter
import ../benchmarks/nim/adapters/lockfreequeues_mupsic_adapter
import ../benchmarks/nim/adapters/lockfreequeues_unbounded_sipsic_adapter
import ../benchmarks/nim/adapters/lockfreequeues_unbounded_sipmuc_adapter
import ../benchmarks/nim/adapters/lockfreequeues_unbounded_mupmuc_adapter

const SmokeMessageCount = 100

proc roundTripUint64Set[A](
    adapter: var A, count: int
): tuple[popped: int, ok: bool] =
  ## Push `count` sequential uint64s, then pop them all back. Returns
  ## (popped_count, set_equality_ok).
  for i in 0 ..< count:
    let r = adapter.push(uint64(i))
    if r != prSuccess:
      return (i, false)
  var seen = initHashSet[uint64]()
  for _ in 0 ..< count:
    let r = adapter.pop()
    if not r.success:
      return (seen.len, false)
    seen.incl(r.value)
  var expected = initHashSet[uint64]()
  for i in 0 ..< count:
    expected.incl(uint64(i))
  result = (seen.len, seen == expected)

suite "bench_common adapters: lockfreequeues smoke (Task 0.8)":
  test "Sipmuc 1024-cap, 1p1c, 100 sequential round-trip":
    var a = makeLockfreequeuesSipmucAdapter[1024, 1, uint64](1024)
    let r = roundTripUint64Set(a, SmokeMessageCount)
    a.cleanup()
    check r.popped == SmokeMessageCount
    check r.ok

  test "Mupsic 1024-cap, 1p1c, 100 sequential round-trip":
    var a = makeLockfreequeuesMupsicAdapter[1024, 1, uint64](1024)
    let r = roundTripUint64Set(a, SmokeMessageCount)
    a.cleanup()
    check r.popped == SmokeMessageCount
    check r.ok

  test "UnboundedSipsic seg=64, 100 sequential round-trip":
    var a = makeLockfreequeuesUnboundedSipsicAdapter[64, uint64](0)
    let r = roundTripUint64Set(a, SmokeMessageCount)
    a.cleanup()
    check r.popped == SmokeMessageCount
    check r.ok

  test "UnboundedSipmuc seg=64, MaxThreads=4, 100 sequential round-trip":
    var a = makeLockfreequeuesUnboundedSipmucAdapter[64, uint64, 4](0)
    let r = roundTripUint64Set(a, SmokeMessageCount)
    a.cleanup()
    check r.popped == SmokeMessageCount
    check r.ok

  test "UnboundedMupmuc seg=64, MaxThreads=4, 100 sequential round-trip":
    var a = makeLockfreequeuesUnboundedMupmucAdapter[64, uint64, 4](0)
    let r = roundTripUint64Set(a, SmokeMessageCount)
    a.cleanup()
    check r.popped == SmokeMessageCount
    check r.ok

# ---------- Task 0.10 (legacy bench_throughput integration) ----------
#
# PR 0 Task 0.10 originally compiled bench_throughput.nim against
# `--bmf-out=` and asserted the emitted BMF carried the expected
# `lockfreequeues_sipsic/spsc/1p1c` slug. PR 2 Task 2.10 deleted
# bench_throughput.nim in favor of five topology-split binaries, and
# tests/t_topology_split.nim now covers the equivalent BMF-emission
# contract for each new binary (bench_spsc covers the sipsic/spsc/1p1c
# slug specifically). The bench_throughput-specific suite is removed
# here intentionally; do not reintroduce.
