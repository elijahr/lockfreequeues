## Bounded SPSC throughput bench (Track 2 PR 2 Task 2.3).
##
## Splits the SPSC slice out of the legacy bench_throughput.nim into a
## standalone binary so CI can budget SPSC and MPMC independently
## (design 2.5; impl plan Track 2). Covers the single Sipsic queue at
## the canonical `1p1c` smoke shape — the Sipsic type only supports
## one producer and one consumer by construction.
##
## Per-binary intdefines (design §2.5):
##   -d:BenchSpscRuns=<N>          (default 33)
##   -d:BenchSpscMessageCount=<N>  (default 1_000_000)
##   -d:BenchSpscWarmup=<N>        (default 3)
##
## Emitted measure per slug: `throughput_ops_ms` (mean, lower=mean-1σ,
## upper=mean+1σ). Slug shape: `lockfreequeues_sipsic/spsc/1p1c`.

import std/[options, os, parseopt, strformat, syncio]
import ./bench_common
import ./adapters/lockfreequeues_sipsic_adapter

# MVP comparison adapters (Track 3). Each is included only when its
# `-d:adapter_<lib>_available` gate is set; absent gate yields no
# symbol references and the variant is dropped from `SupportedVariants`
# below via `when declared(...)`.
when defined(adapter_boost_lockfree_spsc_available):
  import ./adapters/boost_lockfree_spsc_adapter

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
      "BenchSpscMessageCount default must be 1_000_000 (got " &
      $BenchSpscMessageCount & ")"
    doAssert BenchSpscWarmup == 3,
      "BenchSpscWarmup default must be 3 (got " & $BenchSpscWarmup & ")"

const SpscCapacity = 1024

# Variant queueInit closure. `runThroughputHarness` takes a
# `proc(capacity: int): Q` factory; SipsicAdapter ignores the runtime
# capacity arg in favor of its static parameter.
proc initSipsicQ(capacity: int): SipsicAdapter[SpscCapacity, uint64] =
  doAssert capacity == SpscCapacity, "capacity must equal SpscCapacity"
  initSipsicAdapter[SpscCapacity, uint64]()

when defined(adapter_boost_lockfree_spsc_available):
  proc initBoostSpscQ(capacity: int): BoostLockfreeSpscAdapter[uint64] =
    makeBoostLockfreeSpscAdapter[uint64](capacity)

# ---------- Adapter procs (topology-based dispatch) ----------
#
# Each adapter proc emits its hardcoded slug grid. The `topology` arg is
# informational metadata; slug emission is invariant across topology
# inputs (sipsic always emits `lockfreequeues_sipsic/spsc/1p1c`).

proc runMvpVariant[A](
    em: var BMFEmitter,
    slug: string,
    queueInit: proc(capacity: int): A,
    capacity: int,
) =
  ## Generic emitter for MVP comparison adapters: 1p1c throughput at
  ## the same shape as the in-tree sipsic baseline so Bencher can compare
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
    slug, "throughput_ops_ms",
    metrics.ops_ms_mean,
    metrics.ops_ms_mean - metrics.ops_ms_stddev,
    metrics.ops_ms_mean + metrics.ops_ms_stddev,
  )

proc runSipsic(em: var BMFEmitter, topology: Topology) {.nimcall.} =
  discard topology  # informational only; slug hardcoded below
  let slug = "lockfreequeues_sipsic/spsc/1p1c"
  echo fmt"sipsic ({slug}):"
  let metrics = runThroughputHarness[SipsicAdapter[SpscCapacity, uint64]](
    queueInit = initSipsicQ,
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
    slug, "throughput_ops_ms",
    metrics.ops_ms_mean,
    metrics.ops_ms_mean - metrics.ops_ms_stddev,
    metrics.ops_ms_mean + metrics.ops_ms_stddev,
  )

when declared(initBoostSpscQ):
  proc runBoostLockfreeSpsc(em: var BMFEmitter,
                            topology: Topology) {.nimcall.} =
    discard topology
    runMvpVariant[BoostLockfreeSpscAdapter[uint64]](
      em,
      slug = "boost_lockfree_queue/spsc/1p1c",
      queueInit = initBoostSpscQ,
      capacity = SpscCapacity,
    )

# ---------- Adapter registry ----------

proc buildAdapters(): seq[Adapter] =
  result.add(Adapter(
    name: "sipsic",
    topologiesSupported: {tSpsc},
    run: runSipsic,
  ))
  when declared(initBoostSpscQ):
    result.add(Adapter(
      name: "boost_lockfree_spsc",
      topologiesSupported: {tSpsc},
      run: runBoostLockfreeSpsc,
    ))

let adapters: seq[Adapter] = buildAdapters()

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
      of cmdEnd: break
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

  # Topology filter: zero positionals = run every adapter (preserves the
  # legacy "give me the whole binary" semantics that t_topology_split
  # and the snapshot fixture rely on). One positional = topology slug;
  # only adapters whose `topologiesSupported` set contains that topology
  # run. Additional positionals (e.g. `<shape>` from the design example)
  # are accepted and ignored — slug emission is hardcoded inside each
  # adapter proc per the topology-based dispatch convention.
  var topologyFilter: Option[Topology] = none(Topology)
  if positional.len >= 1:
    try:
      topologyFilter = some(parseTopology(positional[0]))
    except ValueError as e:
      echo "Unknown topology: ", positional[0]
      echo "Reason: ", e.msg
      quit 1

  echo "SPSC Throughput Benchmark"
  echo "========================="
  echo ""

  var emitter = initBMFEmitter()
  for adapter in adapters:
    if topologyFilter.isNone:
      # Run every adapter at every topology it supports.
      for t in adapter.topologiesSupported:
        adapter.run(emitter, t)
    elif topologyFilter.get in adapter.topologiesSupported:
      adapter.run(emitter, topologyFilter.get)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
