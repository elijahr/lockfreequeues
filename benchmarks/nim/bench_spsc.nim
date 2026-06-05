## Bounded SPSC throughput bench.
##
## Standalone binary for the SPSC slice, split out of the legacy
## bench_throughput.nim so CI can budget SPSC and MPMC independently.
## Covers the single Spsc queue at the canonical `1p1c` smoke shape
## — the Spsc type only supports one producer and one consumer by
## construction.
##
## Per-binary intdefines (design §2.5):
##   -d:BenchSpscRuns=<N>          (default 33)
##   -d:BenchSpscMessageCount=<N>  (default 1_000_000)
##   -d:BenchSpscWarmup=<N>        (default 3)
##
## Emitted measure per slug: `throughput_ops_ms` (mean, lower=mean-1σ,
## upper=mean+1σ). Slug shape: `lockfreequeues_spsc/spsc/1p1c`.

import std/[options, os, parseopt, sets, strformat, syncio]
import ./bench_common
import ./adapters/lockfreequeues_spsc_adapter
# Consolidated Queue-based parity adapter.
import ./adapters/queue_bounded_adapter
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

# Comparison adapters. Each is included only when its
# `-d:adapter_<lib>_available` gate is set; absent gate yields no
# symbol references and the variant is dropped from `SupportedVariants`
# below via `when declared(...)`.
when defined(adapter_boost_lockfree_spsc_available):
  import ./adapters/boost_lockfree_spsc_adapter

# Tier 1 vendored comparison adapters (header-only C++).
# Both `atomic_queue` (max0x7ba) and `rigtorp::SPSCQueue` are bounded
# rings; gated by per-library defines. atomic_queue runs at SPSC here
# (it is general MPMC, but the SPSC slot exercises its 1p1c path).
when defined(adapter_atomic_queue_available):
  import ./adapters/atomic_queue_adapter

when defined(adapter_rigtorp_spsc_available):
  import ./adapters/rigtorp_spsc_adapter

# Tier 2 Rust comparison adapter: kanal exposes a bounded MPMC channel
# that we exercise here at the 1p1c (SPSC) shape.
when defined(adapter_kanal_available):
  import ./adapters/kanal_adapter

# Tier 3 vendored adapter: liblfds 7.1.1 (C library,
# license-verified public-domain + permissive grant). The adapter
# routes the SPSC topology to the upstream `lfds711_queue_bss_*`
# bounded single-producer / single-consumer queue.
when defined(adapter_liblfds_available):
  import ./adapters/liblfds_adapter

const
  ## Per-binary intdefines for SPSC wall-time control. Override at compile
  ## time with `-d:BenchSpscRuns=N` etc. Defaults match design §2.5.
  BenchSpscRuns* {.intdefine.} = 33
  BenchSpscMessageCount* {.intdefine.} = 1_000_000
  BenchSpscWarmup* {.intdefine.} = 3

# Compile-time test gates — only set by tests/t_topology_split.nim or a
# dedicated build. Production builds never set them.
when defined(BenchSpscTestCompileTime):
  static:
    doAssert BenchSpscRuns == 33,
      "BenchSpscRuns default must be 33 (got " & $BenchSpscRuns & ")"
    doAssert BenchSpscMessageCount == 1_000_000,
      "BenchSpscMessageCount default must be 1_000_000 (got " & $BenchSpscMessageCount &
        ")"
    doAssert BenchSpscWarmup == 3,
      "BenchSpscWarmup default must be 3 (got " & $BenchSpscWarmup & ")"

const SpscCapacity = 1024

# Variant queueInit closure. `runThroughputHarness` takes a
# `proc(capacity: int): Q` factory; SpscAdapter ignores the runtime
# capacity arg in favor of its static parameter.
proc initSpscQ(capacity: int): SpscAdapter[SpscCapacity, uint64] =
  doAssert capacity == SpscCapacity, "capacity must equal SpscCapacity"
  initSpscAdapter[SpscCapacity, uint64]()

# Parallel factory via the consolidated
# QueueBoundedAdapter at SPSC cardinality. Slug
# `lockfreequeues_queue_bounded_spsc/spsc/1p1c`. Output metric +
# units (throughput_ops_ms) identical to the legacy spsc baseline
# so parity tooling can compute a % delta directly.
proc initQueueBoundedSpscQ(
    capacity: int
): QueueBoundedAdapter[ccSingle, ccSingle, stEager, SpscCapacity, 0, 0, uint64] =
  doAssert capacity == SpscCapacity, "capacity must equal SpscCapacity"
  makeQueueBoundedAdapter[ccSingle, ccSingle, stEager, SpscCapacity, 0, 0, uint64](
    SpscCapacity
  )

when defined(adapter_boost_lockfree_spsc_available):
  proc initBoostSpscQ(capacity: int): BoostLockfreeSpscAdapter[uint64] =
    makeBoostLockfreeSpscAdapter[uint64](capacity)

when defined(adapter_atomic_queue_available):
  proc initAtomicQueueQ(capacity: int): AtomicQueueAdapter[uint64] =
    makeAtomicQueueAdapter[uint64](capacity)

when defined(adapter_rigtorp_spsc_available):
  proc initRigtorpSpscQ(capacity: int): RigtorpSpscAdapter[uint64] =
    makeRigtorpSpscAdapter[uint64](capacity)

when defined(adapter_kanal_available):
  proc initKanalSpscQ(capacity: int): KanalAdapter[uint64] =
    makeKanalAdapter[uint64](capacity)

when defined(adapter_liblfds_available):
  proc initLiblfdsSpscQ(capacity: int): LiblfdsAdapter[uint64] =
    # SPSC slot uses the bounded single-producer / single-consumer queue
    # (`lfds711_queue_bss_*`); see the adapter doc-comment for the
    # ringbuffer-vs-bounded-queue rationale.
    makeLiblfdsAdapter[uint64](kind = lkBss, capacity = capacity)

# MVP variants are added to SupportedVariants only when the matching
# adapter symbol is in scope (i.e. its compile-time gate is set).
proc supportedVariantsList(): seq[string] {.compileTime.} =
  result = @["spsc", "queue_bounded_spsc"]
  when declared(initBoostSpscQ):
    result.add("boost_lockfree_spsc")
  when declared(initAtomicQueueQ):
    result.add("atomic_queue")
  when declared(initRigtorpSpscQ):
    result.add("rigtorp_spsc")
  when declared(initKanalSpscQ):
    result.add("kanal")
  when declared(initLiblfdsSpscQ):
    result.add("liblfds")

const SupportedVariants = supportedVariantsList()

proc runMvpVariant[A](
    em: var BMFEmitter, slug: string, queueInit: proc(capacity: int): A, capacity: int
) =
  ## Generic emitter for MVP comparison adapters: 1p1c throughput at
  ## the same shape as the in-tree spsc baseline so Bencher can compare
  ## across libraries on identical work.
  echo fmt"{slug}:"
  let metrics = runThroughputHarness[A](
    queueInit = queueInit,
    capacity = capacity,
    numProducers = 1,
    numConsumers = 1,
    messageCount = BenchSpscMessageCount,
    runCount = BenchSpscRuns,
    warmupCount = BenchSpscWarmup,
  )
  echo fmt"  mean: {metrics.ops_ms_mean:.1f} ops/ms"
  echo fmt"  stddev: {metrics.ops_ms_stddev:.1f}"
  echo fmt"  runs: {metrics.runs}"
  echo ""
  em.addMeasure(
    slug,
    "throughput_ops_ms",
    metrics.ops_ms_mean,
    metrics.ops_ms_mean - metrics.ops_ms_stddev,
    metrics.ops_ms_mean + metrics.ops_ms_stddev,
  )

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "spsc":
    let slug = "lockfreequeues_spsc/spsc/1p1c"
    echo fmt"{variant} ({slug}):"
    let metrics = runThroughputHarness[SpscAdapter[SpscCapacity, uint64]](
      queueInit = initSpscQ,
      capacity = SpscCapacity,
      numProducers = 1,
      numConsumers = 1,
      messageCount = BenchSpscMessageCount,
      runCount = BenchSpscRuns,
      warmupCount = BenchSpscWarmup,
    )
    echo fmt"  mean: {metrics.ops_ms_mean:.1f} ops/ms"
    echo fmt"  stddev: {metrics.ops_ms_stddev:.1f}"
    echo fmt"  runs: {metrics.runs}"
    echo ""
    em.addMeasure(
      slug,
      "throughput_ops_ms",
      metrics.ops_ms_mean,
      metrics.ops_ms_mean - metrics.ops_ms_stddev,
      metrics.ops_ms_mean + metrics.ops_ms_stddev,
    )
  of "queue_bounded_spsc":
    # Same shape as the `spsc` variant above, but
    # backed by the unified `BQueue[T, ccSingle, ccSingle, stEager,
    # rkNone, N, 0, 0, 0, 0]` generic via `QueueBoundedAdapter`. Slug +
    # metric mirror so the parity delta is a simple per-shape division
    # across the two emitted measures.
    let slug = "lockfreequeues_queue_bounded_spsc/spsc/1p1c"
    echo fmt"{variant} ({slug}):"
    let metrics = runThroughputHarness[
      QueueBoundedAdapter[ccSingle, ccSingle, stEager, SpscCapacity, 0, 0, uint64]
    ](
      queueInit = initQueueBoundedSpscQ,
      capacity = SpscCapacity,
      numProducers = 1,
      numConsumers = 1,
      messageCount = BenchSpscMessageCount,
      runCount = BenchSpscRuns,
      warmupCount = BenchSpscWarmup,
    )
    echo fmt"  mean: {metrics.ops_ms_mean:.1f} ops/ms"
    echo fmt"  stddev: {metrics.ops_ms_stddev:.1f}"
    echo fmt"  runs: {metrics.runs}"
    echo ""
    em.addMeasure(
      slug,
      "throughput_ops_ms",
      metrics.ops_ms_mean,
      metrics.ops_ms_mean - metrics.ops_ms_stddev,
      metrics.ops_ms_mean + metrics.ops_ms_stddev,
    )
  else:
    when declared(initBoostSpscQ):
      if variant == "boost_lockfree_spsc":
        runMvpVariant[BoostLockfreeSpscAdapter[uint64]](
          em,
          slug = "boost_lockfree_queue/spsc/1p1c",
          queueInit = initBoostSpscQ,
          capacity = SpscCapacity,
        )
        return
    when declared(initAtomicQueueQ):
      if variant == "atomic_queue":
        runMvpVariant[AtomicQueueAdapter[uint64]](
          em,
          slug = "atomic_queue/spsc/1p1c",
          queueInit = initAtomicQueueQ,
          capacity = SpscCapacity,
        )
        return
    when declared(initRigtorpSpscQ):
      if variant == "rigtorp_spsc":
        runMvpVariant[RigtorpSpscAdapter[uint64]](
          em,
          slug = "rigtorp_spsc/spsc/1p1c",
          queueInit = initRigtorpSpscQ,
          capacity = SpscCapacity,
        )
        return
    when declared(initKanalSpscQ):
      if variant == "kanal":
        runMvpVariant[KanalAdapter[uint64]](
          em,
          slug = "kanal/spsc/1p1c",
          queueInit = initKanalSpscQ,
          capacity = SpscCapacity,
        )
        return
    when declared(initLiblfdsSpscQ):
      if variant == "liblfds":
        runMvpVariant[LiblfdsAdapter[uint64]](
          em,
          slug = "liblfds/spsc/1p1c",
          queueInit = initLiblfdsSpscQ,
          capacity = SpscCapacity,
        )
        return
    raise newException(ValueError, "unknown variant: " & variant)

when isMainModule:
  # Unbuffer stdout so progress is visible under file redirects (mirrors
  # bench_throughput / bench_latency). Long runs under a redirected pipe
  # would otherwise look like a hang.
  setStdIoUnbuffered()

  var bmfOutPath = ""
  var positional: seq[string] = @[]
  block parseCli:
    var p = initOptParser(commandLineParams())
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdLongOption, cmdShortOption:
        case p.key
        of "bmf-out":
          if p.val.len == 0:
            echo "Missing value for --bmf-out"
            quit 1
          bmfOutPath = p.val
        else:
          echo "Unknown flag: --", p.key
          quit 1
      of cmdArgument:
        positional.add(p.key)

  let supported = SupportedVariants.toHashSet
  let runVariants =
    if positional.len == 0:
      supported
    else:
      var groups = initHashSet[string]()
      for arg in positional:
        if arg notin supported:
          echo "Unknown variant: ", arg
          echo "Supported: ", SupportedVariants
          quit 1
        groups.incl arg
      groups

  echo "SPSC Throughput Benchmark"
  echo "========================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
