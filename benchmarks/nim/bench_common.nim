## Shared bench harness primitives.
##
## Public API surface for all five topology-split bench binaries:
##
## - `Topology` enum and `BenchAdapter` concept.
## - `BMFEmitter`: native Bencher Metric Format JSON emission.
## - `Stats` helpers (mean / stddev / minVal / maxVal / percentile).
## - `Histogram` with min-heap top-K + uniform reservoir for online
##   percentile tracking.
## - `runThroughputHarness` and `runLatencyHarness` generic over the
##   queue type.
##
## See design doc section 2.1 at
## /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-design.md
## for the contract.
##
## Task 0.1 ships a compile-only stub: types and proc signatures are
## final, bodies raise `AssertionDefect` with "not implemented" so
## downstream tasks (0.2-0.6) can be written and reviewed in parallel
## while the implementation lands behind them.

import std/[algorithm, heapqueue, json, math, options, random, tables]

# ---------- Topology ----------

type
  Topology* = enum
    tSpsc
    tMpsc
    tMpmc
    tSpscUnbounded
    tMpscUnbounded
    tMpmcUnbounded

# ---------- Adapter primitives ----------

type
  PushResult* = enum
    prSuccess
    prFull

  PopResult*[T] = object
    success*: bool
    value*: T

# ---------- BMF emission ----------

type
  MeasureValue* = object
    value*: float
    lower*: Option[float]
    upper*: Option[float]

  BMFEmitter* = object
    data*: Table[string, Table[string, MeasureValue]]

proc initBMFEmitter*(): BMFEmitter =
  ## Construct an empty BMFEmitter.
  result.data = initTable[string, Table[string, MeasureValue]]()

proc toBound(v: float): Option[float] =
  ## NaN sentinel -> none[float](); finite values -> some(v).
  if v.classify == fcNaN: none(float) else: some(v)

proc addMeasure*(
    em: var BMFEmitter,
    slug: string,
    measure: string,
    value: float,
    lower: float = NaN,
    upper: float = NaN,
) =
  ## Record one measure on one slug. NaN sentinels for `lower` / `upper`
  ## map to `none[float]()`; finite values map to `some(v)`.
  if slug notin em.data:
    em.data[slug] = initTable[string, MeasureValue]()
  em.data[slug][measure] = MeasureValue(
    value: value,
    lower: toBound(lower),
    upper: toBound(upper),
  )

proc emit*(em: BMFEmitter, path: string) =
  ## Write the accumulated BMF data to `path`. Slugs alpha-sorted; within
  ## each slug, measures alpha-sorted. Optional bounds omitted when none.
  let root = newJObject()
  var slugs: seq[string]
  for slug in em.data.keys:
    slugs.add(slug)
  slugs.sort()
  for slug in slugs:
    let inner = em.data[slug]
    let slugNode = newJObject()
    var measures: seq[string]
    for m in inner.keys:
      measures.add(m)
    measures.sort()
    for measure in measures:
      let mv = inner[measure]
      let mNode = newJObject()
      mNode["value"] = newJFloat(mv.value)
      if mv.lower.isSome:
        mNode["lower_value"] = newJFloat(mv.lower.get)
      if mv.upper.isSome:
        mNode["upper_value"] = newJFloat(mv.upper.get)
      slugNode[measure] = mNode
    root[slug] = slugNode
  writeFile(path, pretty(root, 2) & "\n")

# ---------- Stats helpers ----------

proc mean*(data: openArray[float]): float =
  raiseAssert "not implemented"

proc stddev*(data: openArray[float]): float =
  raiseAssert "not implemented"

proc minVal*(data: openArray[float]): float =
  raiseAssert "not implemented"

proc maxVal*(data: openArray[float]): float =
  raiseAssert "not implemented"

proc percentile*(data: openArray[float], p: float): float =
  raiseAssert "not implemented"

# ---------- Histogram (top-K min-heap + uniform reservoir) ----------

const
  HistogramTopK* = 1000        ## exact top-K largest samples seen
  HistogramReservoir* = 99_000 ## uniform sample of the body distribution

type
  Histogram* = object
    topKHeap*: HeapQueue[float]
    reservoir*: seq[float]
    seenAll*: int
    seenBody*: int
    rng*: Rand
    debugAll*: seq[float]

proc initHistogram*(debug: bool = false): Histogram =
  ## Construct an empty Histogram. `debug=true` populates `debugAll` so
  ## `percentile` returns the exact sort answer (used by tests).
  raiseAssert "not implemented"

proc record*(h: var Histogram, value: float) =
  ## Insert a sample. O(log K) amortized.
  raiseAssert "not implemented"

proc topK*(h: Histogram): seq[float] =
  ## Return the top-K samples sorted ascending.
  raiseAssert "not implemented"

proc percentile*(h: Histogram, p: float): float =
  ## Estimate the p-th percentile per the lookup rule in design 2.1.
  raiseAssert "not implemented"

# ---------- Latency harness ----------

type
  LatencyMetrics* = object
    p50_ns*: float
    p95_ns*: float
    p99_ns*: float
    p999_ns*: float
    max_ns*: float
    samples*: int

proc runLatencyHarness*[Q](
    queueInit: proc(): Q,
    messageCount: int,
    runCount: int,
    warmupCount: int,
): LatencyMetrics =
  ## Ping-pong RTT runner. Allocates two queues of type Q (forward +
  ## reverse). Records per-run RTT into a Histogram; reported metrics
  ## are the mean across runs of each percentile.
  raiseAssert "not implemented"

# ---------- Throughput harness ----------

type
  ThroughputMetrics* = object
    ops_ms_mean*: float
    ops_ms_stddev*: float
    runs*: int

proc runThroughputHarness*[Q](
    queueInit: proc(capacity: int): Q,
    capacity: int,
    numProducers: int,
    numConsumers: int,
    messageCount: int,
    runCount: int,
    warmupCount: int,
): ThroughputMetrics =
  ## N-producer / N-consumer throughput runner. Bumps shared atomic
  ## counters; spreads `messageCount mod {P,C}` over the first workers
  ## to avoid the deadlock that a naive `messageCount div N` would
  ## introduce when the count is not divisible.
  raiseAssert "not implemented"
