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

import std/[algorithm, atomics, heapqueue, json, math, monotimes, options,
            os, random, tables, times]
import debra/atomics/backoff  # cpuPause, schedYield directly from debra

# ---------- Harness backoff runtime toggle (Task 02, v4.3) ----------
#
# When `LFQ_BENCH_HARNESS_BACKOFF=0` is set in the environment at process
# start, `HarnessBackoff.backoff` early-returns immediately, exposing
# the queue's CAS-retry path end-to-end without the harness's
# spin-then-yield safety net. Default behavior (env var unset or `=1`)
# is unchanged.
#
# The env var is read **once** at module init via this top-level `let`
# binding so there is zero `getEnv` cost in the bench hot path. In-process
# `putEnv` after import will NOT exercise the cache; the toggle is
# tested out-of-process by the `benchToggleSmoke` nimble task.
#
# Exported so tests can assert the default-case value.
let disableHarnessBackoff* = getEnv("LFQ_BENCH_HARNESS_BACKOFF", "1") == "0"

# ---------- Harness backoff (consumer-side, oversubscription defense-in-depth) ----------
#
# Per-consumer backoff state machine used by the unbounded bench harness.
# Spins via `cpuPause` for the first `HarnessSpinBudget` iterations of an
# empty-pop streak, then escalates to `schedYield` once cumulative spin
# count crosses `HarnessYieldThreshold`. This gives oversubscribed bench
# shapes (e.g. 4p4c on a 4-vCPU CI runner) a way to release the CPU
# quantum back to peers instead of starving on contended pops.
#
# Both knobs are `intdefine` (defaults 128 / 1024); tune at compile time
# via `-d:HarnessSpinBudget=N` / `-d:HarnessYieldThreshold=N`.
#
# Task 11 (shipped in v4.3) relaxed the strict-FIFO consumer claim via a
# wait-free fetchAdd-based head advance, which is the canonical fix for
# the original livelock shape. The harness backoff is retained as
# defense-in-depth for oversubscribed runners where the queue-side
# pop path can still burn CPU under heavy contention. The wrapper is
# intentionally NOT named `backoffOnPeerWait` to avoid shadowing the
# queue-side helper for import discipline.

const
  HarnessSpinBudget* {.intdefine.} = 128
  HarnessYieldThreshold* {.intdefine.} = 1024

type HarnessBackoff* = object
  spinsRemaining: int
  spinsConsumed: int

proc initHarnessBackoff*(): HarnessBackoff =
  result.spinsRemaining = HarnessSpinBudget
  result.spinsConsumed = 0

proc backoff*(b: var HarnessBackoff) {.inline.} =
  # Task 02 (v4.3): runtime kill-switch. When the cached toggle is on
  # (LFQ_BENCH_HARNESS_BACKOFF=0 at process start), exit before any
  # cpuPause / schedYield so the bench observes the queue's behavior
  # end-to-end without the harness backoff smoothing CAS-retry
  # latency cliffs. Default path (toggle false) is unchanged.
  if disableHarnessBackoff: return
  # Restructured so every call that does NOT escalate to a scheduler
  # yield issues exactly one `cpuPause` (preserves a uniform pause
  # cadence). The previous shape skipped the pause whenever the spin
  # budget was reset, even though a reset without yield is just a
  # bookkeeping step between two pause-emitting iterations.
  if b.spinsRemaining <= 0:
    if b.spinsConsumed >= HarnessYieldThreshold:
      schedYield()
      b.spinsConsumed = 0
      b.spinsRemaining = HarnessSpinBudget
      return
    b.spinsRemaining = HarnessSpinBudget
  cpuPause()
  dec b.spinsRemaining
  inc b.spinsConsumed

# ---------- Topology ----------

type
  Topology* = enum
    tSpsc
    tMpsc
    tMpmc
    tSpmc
    tSpscUnbounded
    tMpscUnbounded
    tSpmcUnbounded
    tMpmcUnbounded

proc parseTopology*(s: string): Topology =
  ## Parse a topology slug (e.g. "spsc", "mpmc_unbounded") into a
  ## `Topology` enum value. Used by the per-binary topology dispatcher
  ## introduced with the topology-based `Adapter` registry.
  ##
  ## Raises `ValueError` on an unrecognized slug — callers (typically a
  ## bench binary's `main`) decide whether to exit nonzero or propagate.
  case s
  of "spsc": tSpsc
  of "mpsc": tMpsc
  of "mpmc": tMpmc
  of "spmc": tSpmc
  of "spsc_unbounded": tSpscUnbounded
  of "mpsc_unbounded": tMpscUnbounded
  of "spmc_unbounded": tSpmcUnbounded
  of "mpmc_unbounded": tMpmcUnbounded
  else: raise newException(ValueError, "unknown topology: " & s)

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
  ## A non-finite (`inf`/`-inf`) bound also maps to `none` so we never
  ## emit a non-finite number — `merge_bmf.py` rejects those at upload
  ## time and would fail CI on the whole bench rather than just this
  ## measure.
  case v.classify
  of fcNaN, fcInf, fcNegInf: none(float)
  else: some(v)

proc addMeasure*(
    em: var BMFEmitter,
    slug: string,
    measure: string,
    value: float,
    lower: float = NaN,
    upper: float = NaN,
) =
  ## Record one measure on one slug. NaN/inf sentinels for `lower` /
  ## `upper` map to `none[float]()`; finite values map to `some(v)`.
  ##
  ## Defense-in-depth: if `value` itself is non-finite (NaN or inf —
  ## e.g. a zero-duration measurement that escaped the harness's
  ## `elapsedNs <= 0` guard) we silently skip recording the measure
  ## rather than poisoning the BMF JSON. `merge_bmf.py` rejects
  ## non-finite numbers and would fail the entire upload on a single
  ## bad value; dropping the offending (slug, measure) entry preserves
  ## the rest of the run. The dropped measure is visible in the
  ## emitter's stdout (no row appended) so the operator can still see
  ## the gap.
  case value.classify
  of fcNaN, fcInf, fcNegInf: return
  else: discard
  if slug notin em.data:
    em.data[slug] = initTable[string, MeasureValue]()
  em.data[slug][measure] = MeasureValue(
    value: value,
    lower: toBound(lower),
    upper: toBound(upper),
  )

# ---------- Adapter registry (topology-based dispatch) ----------
#
# Each bench binary owns a `seq[Adapter]` registry. The dispatcher loops
# over the registry and invokes every adapter whose `topologiesSupported`
# set contains the requested topology. Adapter procs hardcode their slug
# emission (queue family + topology + shape grid) — the `topology`
# argument passed to `Adapter.run` is informational metadata, not a
# branch input. Slug emission inside an adapter is invariant across
# `Topology` arguments; the registry's `topologiesSupported` declares
# which topologies the adapter expects to be invoked under.

type
  AdapterRunProc* = proc(em: var BMFEmitter, topology: Topology) {.nimcall.}
  Adapter* = object
    name*: string
    topologiesSupported*: set[Topology]
    run*: AdapterRunProc

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
  ## Arithmetic mean. Empty input returns 0.0 (matches the legacy
  ## `benchmarks/nim/stats.nim` contract that this module replaces).
  if data.len == 0: return 0.0
  var s = 0.0
  for x in data: s += x
  s / float(data.len)

proc stddev*(data: openArray[float]): float =
  ## Sample standard deviation (ddof = 1, matches numpy default for
  ## `np.std(..., ddof=1)`). Singleton or empty input returns 0.0.
  if data.len < 2: return 0.0
  let m = mean(data)
  var sumSq = 0.0
  for x in data:
    let d = x - m
    sumSq += d * d
  sqrt(sumSq / float(data.len - 1))

proc minVal*(data: openArray[float]): float =
  if data.len == 0: return 0.0
  result = data[0]
  for x in data:
    if x < result: result = x

proc maxVal*(data: openArray[float]): float =
  if data.len == 0: return 0.0
  result = data[0]
  for x in data:
    if x > result: result = x

proc percentileSorted*(sorted: openArray[float], p: float): float =
  ## Linear-interpolation percentile from `sorted` (caller-sorted ascending).
  ## `p` clamped to [0, 1]. Empty input returns 0.0. Use this when computing
  ## multiple percentiles over the same dataset to amortize the sort cost.
  if sorted.len == 0: return 0.0
  let pc = max(0.0, min(1.0, p))
  let pos = pc * float(sorted.len - 1)
  let lo = int(pos)
  let hi = min(lo + 1, sorted.len - 1)
  let frac = pos - float(lo)
  sorted[lo] + frac * (sorted[hi] - sorted[lo])

proc percentile*(data: openArray[float], p: float): float =
  ## Linear-interpolation percentile over a sorted copy of `data`.
  ## `p` clamped to [0, 1]. Empty input returns 0.0.
  ##
  ## Allocates and sorts on every call. For multiple percentiles over the
  ## same dataset, sort once and call `percentileSorted` instead.
  if data.len == 0: return 0.0
  var sorted = @data
  sorted.sort()
  percentileSorted(sorted, p)

# ---------- Histogram (top-K min-heap + uniform reservoir) ----------

const
  HistogramTopK* = 5000        ## exact top-K largest samples seen.
                               ## `runLatencyHarness` builds a fresh
                               ## Histogram per run and averages
                               ## per-run percentiles (design 2.5);
                               ## each histogram only sees
                               ## `BenchLatencyMessageCount` samples
                               ## (default 100K). K=5000 sizes the
                               ## exact-top-K stratum with headroom
                               ## for `BenchLatencyMessageCount`
                               ## overrides up to ~5M before p999
                               ## starts spilling into the rescaled
                               ## reservoir. At the default 100K, K
                               ## was already big enough at 1K (p999
                               ## tail = 100); the bump is anticipatory.
                               ## Memory cost is 5000 × 8B = 40KB per
                               ## histogram, negligible vs the 99K
                               ## reservoir.
  HistogramReservoir* = 99_000 ## uniform sample of the body distribution

type
  Histogram* = object
    topKHeap*: HeapQueue[float]
    reservoir*: seq[float]
    seenAll*: int
    seenBody*: int
    rng*: Rand
    debugMode*: bool       ## when true, every `record` also appends
                           ## the value to `debugAll` and `percentile`
                           ## reads from there for an exact answer.
    debugAll*: seq[float]

proc initHistogram*(debug: bool = false): Histogram =
  ## Construct an empty Histogram. `debug=true` puts the histogram in
  ## debug mode: every `record` call also appends to `debugAll`, and
  ## `percentile` returns the exact sort answer over `debugAll` instead
  ## of the heap+reservoir estimator. Used by tests / smoke checks.
  result.topKHeap = initHeapQueue[float]()
  result.reservoir = newSeqOfCap[float](HistogramReservoir)
  result.seenAll = 0
  result.seenBody = 0
  # Deterministic seed makes the reservoir reproducible per-Histogram.
  # Callers needing fresh randomness can re-seed via
  # `h.rng = initRand(<seed>)` after construction.
  result.rng = initRand(0xBA5EBA11'i64)
  result.debugMode = debug
  result.debugAll = @[]

proc reservoirAdmit(h: var Histogram, value: float) =
  ## Algorithm R reservoir admission. `seenBody` counts every body
  ## sample (admitted or not) and drives the replacement probability.
  inc h.seenBody
  if h.reservoir.len < HistogramReservoir:
    h.reservoir.add(value)
  else:
    # Replace at random index with probability HistogramReservoir/seenBody.
    let j = h.rng.rand(h.seenBody - 1)
    if j < HistogramReservoir:
      h.reservoir[j] = value

proc record*(h: var Histogram, value: float) =
  ## Insert a sample.
  ##
  ## Top-K: maintain a min-heap of the K largest values.
  ##   - heap.len < K            -> push.
  ##   - else value > heap[0]    -> replace (evicts smallest of top-K
  ##                                 into the body bucket via
  ##                                 reservoirAdmit).
  ##   - else                    -> reservoirAdmit(value).
  ##
  ## Body: Algorithm R reservoir of size R = HistogramReservoir.
  ##
  ## In debug mode we additionally store every value in `debugAll` so
  ## `percentile` returns an exact answer.
  inc h.seenAll
  if h.debugMode:
    h.debugAll.add(value)

  if h.topKHeap.len < HistogramTopK:
    h.topKHeap.push(value)
  elif value > h.topKHeap[0]:
    # `replace` returns the evicted minimum.
    let evicted = h.topKHeap.replace(value)
    reservoirAdmit(h, evicted)
  else:
    reservoirAdmit(h, value)

proc topK*(h: Histogram): seq[float] =
  ## Return the top-K samples sorted ascending. Reads the heap by
  ## copy + sort so the original heap is untouched.
  var copy = h.topKHeap
  result = newSeqOfCap[float](copy.len)
  while copy.len > 0:
    result.add(copy.pop())  # min-heap pop -> ascending order

proc percentile*(h: Histogram, p: float): float =
  ## Estimate the p-th percentile.
  ##
  ## Lookup rule (design 2.1, with stratified-estimator math):
  ##   debug mode                                  -> exact sort(debugAll)
  ##   p == 1.0                                    -> top-K max
  ##   target rank in top-K stratum                -> top-K rank lookup
  ##                       (i.e. seenAll*(1-p) <= heap.len)
  ##   else                                        -> reservoir, with the
  ##     percentile rescaled to the body stratum: p_body = (p*seenAll)
  ##     / (seenAll - K). The reservoir samples uniformly from the body,
  ##     so the rescaled percentile is unbiased.
  ##
  ## Worked example (K=1000, seenAll=100_000):
  ##   p=0.99, target rank 99_000. Top-K covers ranks 99_001..100_000
  ##     (count K=1000), so target is in the body stratum at the very
  ##     top edge. p_body = 99_000 / 99_000 = 1.0 -> reservoir max.
  ##   p=0.999, target rank 99_900. Tail count = 100. <= heap.len -> top-K.
  ##   p=1.0, max -> top-K.
  ##   p=0.50, target rank 50_000 -> body, p_body = 50_000/99_000 ≈ 0.505.
  if h.debugMode:
    return percentile(h.debugAll, p)
  if h.seenAll == 0:
    return 0.0
  let pc = max(0.0, min(1.0, p))
  let topkLen = h.topKHeap.len

  if pc == 1.0:
    if topkLen == 0: return 0.0
    let topk = h.topK()
    return topk[^1]

  # Total samples that ARE in the top-K stratum is exactly `topkLen`
  # (heap fills up to K; before that, every sample is "in top-K" trivially).
  # Tail count = number of samples >= target. If tail <= topkLen, the
  # target lies in the top-K stratum.
  let tailCount = float(h.seenAll) * (1.0 - pc)

  if tailCount <= float(topkLen):
    # Top-K rank lookup. topk sorted ascending, length topkLen.
    # Target is the (topkLen - tailCount)-th element (0-based).
    let topk = h.topK()
    let pos = float(topkLen) - tailCount
    let lo = max(0, int(floor(pos)))
    let hi = min(lo + 1, topk.len - 1)
    let frac = pos - float(lo)
    return topk[lo] + frac * (topk[hi] - topk[lo])

  # Body-stratum lookup with rescaling. body samples = seenAll - topkLen.
  # Target body-rank = pc * seenAll  (since top-K is at the high end and
  # contributes topkLen items above the body).
  let bodySize = h.seenAll - topkLen
  if bodySize <= 0 or h.reservoir.len == 0:
    # All samples ended up in top-K. Fall back to top-K percentile.
    let topk = h.topK()
    if topk.len == 0: return 0.0
    return percentile(topk, pc)
  let pBody = (pc * float(h.seenAll)) / float(bodySize)
  let pBodyClamped = max(0.0, min(1.0, pBody))
  return percentile(h.reservoir, pBodyClamped)

proc percentiles*(h: Histogram, ps: openArray[float]): seq[float] =
  ## Compute multiple percentiles in a single pass. Sorts the reservoir
  ## (and snapshots top-K) at most once regardless of how many percentiles
  ## are requested, so this is O((R + K) log (R + K) + len(ps)) rather
  ## than O(len(ps) * R log R) for repeated single-percentile calls.
  ## Same lookup rules as `percentile(h, p)`.
  result = newSeq[float](ps.len)
  if ps.len == 0: return
  if h.debugMode:
    var sorted = @(h.debugAll)
    sorted.sort()
    for i, p in ps:
      result[i] = percentileSorted(sorted, p)
    return
  if h.seenAll == 0: return  # already zero-initialised
  let topkLen = h.topKHeap.len
  let topkSnap = h.topK()  # ascending; <= K elements
  var reservoirSorted = @(h.reservoir)
  reservoirSorted.sort()
  for i, p in ps:
    let pc = max(0.0, min(1.0, p))
    if pc == 1.0:
      if topkLen == 0: result[i] = 0.0
      else: result[i] = topkSnap[^1]
      continue
    let tailCount = float(h.seenAll) * (1.0 - pc)
    if tailCount <= float(topkLen):
      let pos = float(topkLen) - tailCount
      let lo = max(0, int(floor(pos)))
      let hi = min(lo + 1, topkSnap.len - 1)
      let frac = pos - float(lo)
      result[i] = topkSnap[lo] + frac * (topkSnap[hi] - topkSnap[lo])
      continue
    let bodySize = h.seenAll - topkLen
    if bodySize <= 0 or reservoirSorted.len == 0:
      if topkSnap.len == 0: result[i] = 0.0
      else: result[i] = percentileSorted(topkSnap, pc)
      continue
    let pBody = (pc * float(h.seenAll)) / float(bodySize)
    let pBodyClamped = max(0.0, min(1.0, pBody))
    result[i] = percentileSorted(reservoirSorted, pBodyClamped)

# ---------- Latency harness ----------

type
  LatencyMetrics* = object
    p50_ns*: float
    p95_ns*: float
    p99_ns*: float
    p999_ns*: float
    max_ns*: float
    samples*: int

type
  PingerCtx[Q] = object
    fwd: ptr Q
    rev: ptr Q
    count: int
    chan: ptr Channel[float]
    debugMode: bool

  PongerCtx[Q] = object
    fwd: ptr Q
    rev: ptr Q
    count: int

proc pingerThreadBody[Q](ctx: ptr PingerCtx[Q]) {.thread.} =
  ## Send a monotonic-ns timestamp via the forward queue, spin on the
  ## reverse queue until the ponger echoes it back, record RTT.
  ## `mixin push / pop` defers symbol resolution to the call site.
  ##
  ## Histogram lives entirely on this thread's local heap; after the
  ## measurement loop finishes we drain its classified state to
  ## `ctx.chan` so the main thread can reconstruct a fresh Histogram
  ## without touching this thread's seqs (which refc tears down at
  ## thread exit).
  mixin push, pop
  var hist = initHistogram(ctx.debugMode)
  for _ in 0 ..< ctx.count:
    let t0 = getMonoTime()
    let payload = uint64(inNanoseconds(t0 - MonoTime()))
    while push(ctx.fwd[], payload) == prFull:
      discard
    while true:
      let r = pop(ctx.rev[])
      if r.success:
        let t1 = getMonoTime()
        let rtt = float(inNanoseconds(t1 - t0))
        if rtt > 0.0:
          hist.record(rtt)
        break

  # Drain classified Histogram state to the main thread. The 5-counter
  # prefix is always sent (regardless of debugMode); the main thread
  # sizes its own Histogram from `ctx.debugMode` and ignores the
  # debugAll length when not in debug mode. `joinThread` provides the
  # happens-before edge that makes blocking recv() with known counts
  # safe.
  ctx.chan[].send(float(hist.seenAll))
  ctx.chan[].send(float(hist.seenBody))
  ctx.chan[].send(float(hist.topKHeap.len))
  ctx.chan[].send(float(hist.reservoir.len))
  ctx.chan[].send(float(hist.debugAll.len))
  # HeapQueue's `items` iterator was added in 2.1.1 but isn't picked up
  # consistently across mm modes here, so go through the indexer (which
  # is plain `lent T` access into the underlying seq — heap order, but
  # the main thread re-pushes through `topKHeap.push` so order doesn't
  # matter on the wire).
  for i in 0 ..< hist.topKHeap.len:
    ctx.chan[].send(hist.topKHeap[i])
  for v in hist.reservoir:
    ctx.chan[].send(v)
  for v in hist.debugAll:
    ctx.chan[].send(v)

proc pongerThreadBody[Q](ctx: ptr PongerCtx[Q]) {.thread.} =
  mixin push, pop
  for _ in 0 ..< ctx.count:
    var v: uint64
    while true:
      let r = pop(ctx.fwd[])
      if r.success:
        v = r.value
        break
    while push(ctx.rev[], v) == prFull:
      discard

proc runOneLatencyRun[Q](
    queueInit: proc(): Q,
    messageCount: int,
): LatencyMetrics =
  ## One ping-pong RTT run. Allocates fwd + rev queues of type Q,
  ## spawns 1 pinger and 1 ponger, records RTT samples, returns
  ## LatencyMetrics{p50, p95, p99, p999, max, samples}.
  ##
  ## NOTE: This task ships the 1P/1C smoke topology only. PR 1 (Task 1.x)
  ## extends to multi-pinger / multi-ponger by sharding `messageCount`
  ## across additional threads with the remainder-spread rule from
  ## runThroughputHarness. The 1P/1C path keeps RTT semantics clean
  ## (no scheduler interleave between ping and pong) which is what the
  ## p50 / p99 measurements in PR 1 hinge on.
  var fwd = queueInit()
  var rev = queueInit()

  # Per-run channel for draining the pinger's classified Histogram state
  # across the refc thread-heap boundary. The Channel struct itself is
  # main-thread-allocated (alloc/dealloc both happen here on the main
  # thread); the channel's internal message buffer goes through Nim's
  # shared-heap allocator, so floats sent by the pinger survive its
  # local-heap teardown.
  var chan = create(Channel[float])
  chan[].open(0)  # unbounded
  defer:
    chan[].close()
    dealloc(chan)

  var pingerCtx = PingerCtx[Q](
    fwd: addr fwd, rev: addr rev,
    count: messageCount,
    chan: chan,
    debugMode: false,  # latency harness never enables debugMode today
  )
  var pongerCtx = PongerCtx[Q](
    fwd: addr fwd, rev: addr rev,
    count: messageCount,
  )

  var pingerThread: Thread[ptr PingerCtx[Q]]
  var pongerThread: Thread[ptr PongerCtx[Q]]

  createThread(pingerThread, pingerThreadBody[Q], addr pingerCtx)
  createThread(pongerThread, pongerThreadBody[Q], addr pongerCtx)
  joinThread(pingerThread)
  joinThread(pongerThread)

  # Drain the pinger's classified Histogram state into a fresh
  # main-thread Histogram. joinThread above provides the happens-before
  # edge, and the pinger sent a fixed 5-counter prefix followed by the
  # exact number of floats those counters describe — so blocking recv()
  # cannot deadlock here.
  var hist = initHistogram(pingerCtx.debugMode)
  let seenAll       = int(chan[].recv())
  let seenBody      = int(chan[].recv())
  let topKLen       = int(chan[].recv())
  let reservoirLen  = int(chan[].recv())
  let debugAllLen   = int(chan[].recv())
  for _ in 0 ..< topKLen:
    hist.topKHeap.push(chan[].recv())
  for _ in 0 ..< reservoirLen:
    hist.reservoir.add(chan[].recv())
  if pingerCtx.debugMode:
    for _ in 0 ..< debugAllLen:
      hist.debugAll.add(chan[].recv())
  else:
    # Drain (and discard) any debugAll values the pinger sent so the
    # channel is empty when we close it. Today this branch never fires
    # because debugMode is hard-coded false in the ctx above, but we
    # honor the on-wire protocol so future debug-mode use doesn't leak.
    for _ in 0 ..< debugAllLen:
      discard chan[].recv()
  hist.seenAll  = seenAll
  hist.seenBody = seenBody

  # Bulk-percentile so the reservoir/top-K snapshot is sorted once per
  # run rather than five times. Order MUST match the LatencyMetrics
  # field order below.
  let pcts = hist.percentiles([0.50, 0.95, 0.99, 0.999, 1.0])
  result = LatencyMetrics(
    p50_ns: pcts[0],
    p95_ns: pcts[1],
    p99_ns: pcts[2],
    p999_ns: pcts[3],
    max_ns: pcts[4],
    samples: hist.seenAll,
  )

  # Drop heap-allocated queue state. Adapters whose `Q` heap-allocates
  # (e.g. lockfreequeues bounded adapters via `create(...)`) leak the
  # backing queue otherwise — `var fwd: Q` only frees the adapter
  # struct's own stack slot at scope exit, not the pointee. `when
  # compiles` keeps the harness usable for value-type adapters that
  # don't define a `cleanup`.
  mixin cleanup
  when compiles(cleanup(fwd)):
    cleanup(fwd)
  when compiles(cleanup(rev)):
    cleanup(rev)

proc runLatencyHarness*[Q](
    queueInit: proc(): Q,
    messageCount: int,
    runCount: int,
    warmupCount: int,
): LatencyMetrics =
  ## Ping-pong RTT runner. Allocates two queues of type Q (forward +
  ## reverse). Records per-run RTT into a Histogram; reported metrics
  ## are the **mean across runs of each percentile** (NOT a percentile
  ## of all unioned samples), per design 2.5 "Run aggregation for latency".
  ##
  ## Per-run histograms isolate slow GC pauses or thread-warmup
  ## artifacts to the run that contains them, instead of bleeding into
  ## the next run's tail.
  for _ in 0 ..< warmupCount:
    discard runOneLatencyRun[Q](queueInit, messageCount)
  if runCount <= 0:
    return LatencyMetrics()
  var p50s, p95s, p99s, p999s, maxs: seq[float]
  var totalSamples = 0
  for _ in 0 ..< runCount:
    let m = runOneLatencyRun[Q](queueInit, messageCount)
    p50s.add(m.p50_ns)
    p95s.add(m.p95_ns)
    p99s.add(m.p99_ns)
    p999s.add(m.p999_ns)
    maxs.add(m.max_ns)
    totalSamples += m.samples
  result = LatencyMetrics(
    p50_ns: mean(p50s),
    p95_ns: mean(p95s),
    p99_ns: mean(p99s),
    p999_ns: mean(p999s),
    max_ns: mean(maxs),
    samples: totalSamples,
  )

# ---------- Throughput harness ----------

type
  ThroughputMetrics* = object
    ops_ms_mean*: float
    ops_ms_stddev*: float
    runs*: int

type
  ProducerCtx[Q] = object
    queue: ptr Q
    startIdx: int
    count: int

  ConsumerCtx[Q] = object
    queue: ptr Q
    count: int

proc producerThreadBody[Q](ctx: ptr ProducerCtx[Q]) {.thread.} =
  ## Tight push loop. Spins on `prFull` to keep the harness simple.
  ## `mixin push` defers symbol resolution to instantiation site so the
  ## user's adapter-specific `push` is found.
  mixin push
  for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
    while push(ctx.queue[], uint64(i)) == prFull:
      discard

proc consumerThreadBody[Q](ctx: ptr ConsumerCtx[Q]) {.thread.} =
  mixin pop
  var local = 0
  while local < ctx.count:
    let item = pop(ctx.queue[])
    if item.success:
      inc local

proc runOneThroughputRun[Q](
    queueInit: proc(capacity: int): Q,
    capacity: int,
    numProducers: int,
    numConsumers: int,
    messageCount: int,
): float =
  ## One run of the throughput harness; returns ops/ms.
  ##
  ## Distribution invariants (mirrors legacy bench_throughput
  ## `runThroughputBenchmark`):
  ##   1. sum(producer.count) == messageCount
  ##   2. sum(consumer.count) == messageCount
  ## A naive `messageCount div N` truncates and breaks both when
  ## `messageCount` is not divisible by `numProducers` or `numConsumers`,
  ## which deadlocks the consumers (waiting for items the producers never
  ## enqueue) or strands items in the queue (consumers stop early).
  ## Spread the remainder over the first `messageCount mod N` workers so
  ## totals match exactly for any (P, C, messageCount) triple.
  ##
  ## Misuse guard: `messageCount div numProducers` would crash on
  ## `numProducers = 0` (DivByZeroDefect). The harness is exported, so
  ## a future caller could plausibly pass 0 thinking "no producers" is
  ## a degenerate but valid shape. Fail fast with a clear message
  ## instead of letting div/mod crash the worker thread.
  doAssert numProducers > 0,
    "runThroughputHarness requires numProducers > 0 (got " &
    $numProducers & ")"
  doAssert numConsumers > 0,
    "runThroughputHarness requires numConsumers > 0 (got " &
    $numConsumers & ")"
  doAssert messageCount >= 0,
    "runThroughputHarness requires messageCount >= 0 (got " &
    $messageCount & ")"
  var queue = queueInit(capacity)
  let baseP = messageCount div numProducers
  let remP = messageCount mod numProducers
  let baseC = messageCount div numConsumers
  let remC = messageCount mod numConsumers

  var producerThreads = newSeq[Thread[ptr ProducerCtx[Q]]](numProducers)
  var consumerThreads = newSeq[Thread[ptr ConsumerCtx[Q]]](numConsumers)
  var producerCtxs = newSeq[ProducerCtx[Q]](numProducers)
  var consumerCtxs = newSeq[ConsumerCtx[Q]](numConsumers)

  var nextStart = 0
  for i in 0 ..< numProducers:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = ProducerCtx[Q](
      queue: addr queue,
      startIdx: nextStart,
      count: count,
    )
    nextStart += count

  for i in 0 ..< numConsumers:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = ConsumerCtx[Q](
      queue: addr queue,
      count: count,
    )

  # Monotonic clock — `epochTime` (wall clock) can step backward across
  # NTP adjustments and skew throughput numbers. Nanosecond precision:
  # ms-precision buckets multiple short runs into the same integer ms,
  # producing identical samples and stddev=0 on a fast CI runner. ops/ms
  # is reconstructed as a float at print time.
  let startTime = getMonoTime()

  for i in 0 ..< numProducers:
    createThread(producerThreads[i], producerThreadBody[Q],
                 addr producerCtxs[i])
  for i in 0 ..< numConsumers:
    createThread(consumerThreads[i], consumerThreadBody[Q],
                 addr consumerCtxs[i])

  for i in 0 ..< numProducers:
    joinThread(producerThreads[i])
  for i in 0 ..< numConsumers:
    joinThread(consumerThreads[i])

  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))

  # See `runOneLatencyRun`: `var queue: Q` only frees the adapter
  # struct's stack slot, leaking any heap-allocated backing queue.
  # Run cleanup before any return so the leak is plugged on both the
  # zero-elapsed early return and the normal path.
  mixin cleanup
  when compiles(cleanup(queue)):
    cleanup(queue)

  if elapsedNs <= 0.0:
    return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

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
  ##
  ## Verbatim factor-out of legacy `runThroughputBenchmark` (see
  ## `benchmarks/nim/bench_throughput.nim`) parameterized over the queue
  ## init proc. The producer's payload is `uint64(i)` per BenchAdapter
  ## convention.
  for _ in 0 ..< warmupCount:
    discard runOneThroughputRun[Q](
      queueInit, capacity, numProducers, numConsumers, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runCount:
    samples.add(runOneThroughputRun[Q](
      queueInit, capacity, numProducers, numConsumers, messageCount))
  result = ThroughputMetrics(
    ops_ms_mean: mean(samples),
    ops_ms_stddev: stddev(samples),
    runs: runCount,
  )
