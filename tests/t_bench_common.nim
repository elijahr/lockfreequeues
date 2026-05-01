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
