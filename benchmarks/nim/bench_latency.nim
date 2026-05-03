## Latency benchmark: ping-pong RTT between 2 threads.
##
## Track 1 PR 1 — rewritten on top of `bench_common.runLatencyHarness`.
## Mirrors the bench_throughput CLI surface:
##
##   bench_latency [--bmf-out=<path>] [<variant>...]
##
## Positional args filter the variants to run (legacy, preserved); without
## any positional arg, all four bounded lockfreequeues variants run at the
## 1p1c smoke shape (`sipsic`, `mupmuc`, `sipmuc`, `mupsic`). `--bmf-out`
## emits Bencher Metric Format JSON natively. Stdout text is preserved.
##
## Per-binary intdefines:
##   -d:BenchLatencyRuns=<N>            (default 33)
##   -d:BenchLatencyMessageCount=<N>    (default 100_000)
##   -d:BenchLatencyWarmupRuns=<N>      (default 3)
##
## Emitted measures per slug:
##   latency_p50_ns, latency_p95_ns, latency_p99_ns
##   (latency_p999_ns / latency_max_ns are deferred to PR 6.)
##
## Slug shape: `<library_slug>/<topology>/1p1c` per design 2.2 / table at
## design line 357.

import std/[options, os, parseopt, sets, strformat, syncio]
import ./bench_common
import ./adapters/lockfreequeues_sipsic_adapter
import ./adapters/lockfreequeues_sipmuc_adapter
import ./adapters/lockfreequeues_mupsic_adapter
import ./adapters/lockfreequeues_mupmuc_adapter

const
  ## Per-binary intdefines for latency wall-time control. Mirror the
  ## `BenchSipsicRuns` / `MessageCount` pattern in bench_throughput.nim.
  ## Override at compile time with `-d:BenchLatencyRuns=N` etc.
  BenchLatencyRuns* {.intdefine.} = 33
  BenchLatencyMessageCount* {.intdefine.} = 100_000
  BenchLatencyWarmupRuns* {.intdefine.} = 3

# Compile-time test gates. These flags are set ONLY by
# `tests/t_bench_latency.nim` to assert the intdefine defaults / overrides;
# production builds never set them.
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

# ---------- Variant queueInit closures ----------
#
# `runLatencyHarness` takes a `proc(): Q` factory. The 4 bounded
# adapters have non-uniform factory shapes (`initSipsicAdapter`
# vs `makeLockfreequeuesSipmucAdapter(capacity = N)` etc.) so we
# wrap each in a uniform `proc(): Adapter` closure. Capacity is
# pinned to 1024 — same value used by bench_throughput's sipsic
# slug — to keep latency runs comparable to throughput on the
# shared 1p1c slug.

const LatencyCapacity = 1024

proc initSipsic(): SipsicAdapter[LatencyCapacity, uint64] =
  initSipsicAdapter[LatencyCapacity, uint64]()

proc initSipmuc(): LockfreequeuesSipmucAdapter[LatencyCapacity, 1, uint64] =
  makeLockfreequeuesSipmucAdapter[LatencyCapacity, 1, uint64](LatencyCapacity)

proc initMupsic(): LockfreequeuesMupsicAdapter[LatencyCapacity, 1, uint64] =
  makeLockfreequeuesMupsicAdapter[LatencyCapacity, 1, uint64](LatencyCapacity)

proc initMupmuc(): MupmucAdapter[LatencyCapacity, uint64] =
  initMupmucAdapter[LatencyCapacity, uint64]()

# ---------- Variant dispatch ----------

const SupportedVariants = ["sipsic", "mupmuc", "sipmuc", "mupsic"]

proc slugFor(variant: string): string =
  ## Slug per design 2.2 / table at design line 357. PR 1 covers the 1p1c
  ## smoke shape only; PR 2's topology split adds the full grid.
  case variant
  of "sipsic": "lockfreequeues_sipsic/spsc/1p1c"
  of "sipmuc": "lockfreequeues_sipmuc/mpmc/1p1c"
  of "mupsic": "lockfreequeues_mupsic/mpsc/1p1c"
  of "mupmuc": "lockfreequeues_mupmuc/mpmc/1p1c"
  else:
    raise newException(ValueError, "unknown variant: " & variant)

proc runVariant(
    variant: string, em: var BMFEmitter
) =
  ## Run one variant's latency harness, print stdout, and emit BMF.
  let slug = slugFor(variant)
  echo fmt"{variant} ({slug}):"
  let metrics =
    case variant
    of "sipsic":
      runLatencyHarness[SipsicAdapter[LatencyCapacity, uint64]](
        queueInit = initSipsic,
        messageCount = BenchLatencyMessageCount,
        runCount = BenchLatencyRuns,
        warmupCount = BenchLatencyWarmupRuns,
      )
    of "sipmuc":
      runLatencyHarness[LockfreequeuesSipmucAdapter[LatencyCapacity, 1, uint64]](
        queueInit = initSipmuc,
        messageCount = BenchLatencyMessageCount,
        runCount = BenchLatencyRuns,
        warmupCount = BenchLatencyWarmupRuns,
      )
    of "mupsic":
      runLatencyHarness[LockfreequeuesMupsicAdapter[LatencyCapacity, 1, uint64]](
        queueInit = initMupsic,
        messageCount = BenchLatencyMessageCount,
        runCount = BenchLatencyRuns,
        warmupCount = BenchLatencyWarmupRuns,
      )
    of "mupmuc":
      runLatencyHarness[MupmucAdapter[LatencyCapacity, uint64]](
        queueInit = initMupmuc,
        messageCount = BenchLatencyMessageCount,
        runCount = BenchLatencyRuns,
        warmupCount = BenchLatencyWarmupRuns,
      )
    else:
      raise newException(ValueError, "unknown variant: " & variant)
  # p999 / max are printed for operator visibility but NOT emitted to BMF
  # at this PR (latency_p999_ns / latency_max_ns wire-up is deferred to
  # PR 6 along with their threshold configuration).
  echo fmt"  p50:  {metrics.p50_ns:.0f} ns"
  echo fmt"  p95:  {metrics.p95_ns:.0f} ns"
  echo fmt"  p99:  {metrics.p99_ns:.0f} ns"
  echo fmt"  p999: {metrics.p999_ns:.0f} ns"
  echo fmt"  max:  {metrics.max_ns:.0f} ns"
  echo fmt"  samples: {metrics.samples}"
  echo ""
  em.addMeasure(slug, "latency_p50_ns", metrics.p50_ns)
  em.addMeasure(slug, "latency_p95_ns", metrics.p95_ns)
  em.addMeasure(slug, "latency_p99_ns", metrics.p99_ns)

when isMainModule:
  # Unbuffer stdout so progress is visible when the bench is run under
  # a file redirect (mirrors bench_throughput's setStdIoUnbuffered call).
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
          let prefix = (if p.kind == cmdLongOption: "--" else: "-")
          echo "Unknown flag: ", prefix, p.key
          quit 1
      of cmdArgument:
        positional.add(p.key)

  let supported = SupportedVariants.toHashSet
  let runVariants =
    if positional.len == 0:
      supported
    else:
      var variants = initHashSet[string]()
      for arg in positional:
        if arg notin supported:
          echo "Unknown variant: ", arg
          echo "Supported: ", SupportedVariants
          quit 1
        variants.incl arg
      variants

  echo "Latency Benchmark (ping-pong RTT)"
  echo "================================="
  echo ""

  var emitter = initBMFEmitter()

  # Iterate in a deterministic order (the SupportedVariants array order)
  # so stdout is reproducible across runs and grep-friendly in CI logs.
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
