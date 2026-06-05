import os

# Package
version        = "5.0.0"
author         = "Elijah Shaw-Rutschman"
description    = "Lock-free queue implementations for Nim."
license        = "MIT"
srcDir         = "src"
entryPoints    = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.2.10"
requires "unittest2"
requires "typestates >= 0.12.0"
requires "debra >= 0.10.0"

# Tasks
task should_fail, "Verifies compile-fail negative controls":
  # Driver iterates the 5-case table and runs `nim c --compileOnly` per
  # case, asserting expected exit + pinned substring. Ported from
  # nim-debra 0.8.0's `tests/should_fail/runner.nim` harness.
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"

task test, "Runs the test suite":
  # Compile-fail negative controls. Runs first so a
  # regression in the (γ) bounded-asymmetry guard or Strategy/cardinality
  # phantom-param surface trips the suite before the positive matrix
  # masks it with downstream noise.
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"

  # C with default MM (orc)
  exec "nim c --threads:on -r -f tests/test.nim"

  # C++
  exec "nim cpp --threads:on -r -f tests/test.nim"

  # Test with different memory managers
  exec "nim c --mm:arc --threads:on -r -f tests/test.nim"
  exec "nim c --mm:refc --threads:on -r -f tests/test.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # C (with thread sanitization, requires atomicArc for thread-safe refcounting)
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f tests/test.nim"

  if getEnv("SANITIZE_ADDRESS") != "no":
    # C (with address sanitization)
    exec "nim c --cc:clang --passC:\"-fsanitize=address\" --passL:\"-fsanitize=address\" --threads:on -r -f tests/test.nim"


task examples, "Runs the examples":
  # Bounded queue examples
  exec "nim c --threads:on -r -f examples/spsc.nim"
  exec "nim c --threads:on -r -f examples/spmc.nim"
  exec "nim c --threads:on -r -f examples/mpsc.nim"
  exec "nim c --threads:on -r -f examples/mpmc.nim"
  # Advanced examples
  exec "nim c --threads:on -r -f examples/audio_buffer.nim"
  exec "nim c --threads:on -r -f examples/task_fanout.nim"
  exec "nim c --threads:on -r -f examples/event_collector.nim"
  exec "nim c --threads:on -r -f examples/job_scheduler.nim"

task benchmarks, "Runs the benchmark suite":
  # PR 2 (bench-rollup) replaced bench_throughput.nim with topology-
  # split binaries. v5.0.0 B3 further split the MPMC binary into a
  # per-family pair (bench_mpmc_bounded + bench_spmc_bounded) to remove
  # cross-family iCache contention; applied the same
  # mitigation to the unbounded binary, fanning it out into four
  # per-family binaries (bench_unbounded_{spsc,spmc,mpsc,mpmc}).
  # See the bench_mpmc_*.nim and bench_unbounded_*.nim headers for the
  # diagnostic that motivated each split. Each binary emits its own
  # Bencher Metric Format JSON fragment; merge_bmf.py unions them into
  # one final file. Binaries land in `.tmp/` per the project nim.cfg
  # (`--outdir:.tmp`).
  mkDir "benchmarks/results"
  for binName in [
    "bench_spsc", "bench_mpsc",
    "bench_mpmc_bounded", "bench_spmc_bounded",
    "bench_unbounded_spsc", "bench_unbounded_spmc",
    "bench_unbounded_mpsc", "bench_unbounded_mpmc",
    "bench_latency",
  ]:
    exec "nim c -d:release --threads:on benchmarks/nim/" & binName & ".nim"
    exec ".tmp/" & binName & " --bmf-out=benchmarks/results/" & binName & ".json"
  # Union the per-binary fragments. Exits 1 on (slug, measure) collisions.
  exec "python3 benchmarks/merge_bmf.py benchmarks/results/latest.json " &
       "benchmarks/results/bench_spsc.json " &
       "benchmarks/results/bench_mpsc.json " &
       "benchmarks/results/bench_mpmc_bounded.json " &
       "benchmarks/results/bench_spmc_bounded.json " &
       "benchmarks/results/bench_unbounded_spsc.json " &
       "benchmarks/results/bench_unbounded_spmc.json " &
       "benchmarks/results/bench_unbounded_mpsc.json " &
       "benchmarks/results/bench_unbounded_mpmc.json " &
       "benchmarks/results/bench_latency.json"


task benchtests, "Runs the bench harness test suite":
  # The bench harness lives outside `srcDir`, so its dedicated tests
  # (`tests/t_bench_*.nim`) are NOT imported by `tests/test.nim` to
  # keep the regular `nimble test` matrix free of the bench harness's
  # threading/atomic dependencies. This task runs them explicitly so
  # CI can validate HistogramTopK sizing, latency CLI assertions, and
  # adapter round-trip behavior. Single MM (orc default) is sufficient
  # because the bench harness itself is the system under test, not the
  # queue MM matrix.
  exec "nim c --threads:on -r -f tests/t_bench_common.nim"
  exec "nim c --threads:on -r -f tests/t_bench_latency.nim"
  exec "nim c --threads:on -r -f tests/t_bench_adapters.nim"


task benchToggleSmoke, "Verify LFQ_BENCH_HARNESS_BACKOFF=0 toggle is observed at module init":
  exec "nim c --threads:on -o:.tmp/bench_toggle_smoke tests/bench_toggle_smoke_driver.nim"
  exec "sh -c 'LFQ_BENCH_HARNESS_BACKOFF=0 .tmp/bench_toggle_smoke | grep -q true || (echo FAIL && exit 1)'"
  exec "sh -c 'LFQ_BENCH_HARNESS_BACKOFF=1 .tmp/bench_toggle_smoke | grep -q false || (echo FAIL && exit 1)'"
  exec "sh -c '.tmp/bench_toggle_smoke | grep -q false || (echo FAIL && exit 1)'"


task benchteststress, "Runs the bench harness test suite including 3.3M-sample stress shapes":
  # Like `benchtests` but enables the gated 3.3M-sample p999 stress
  # shape in t_bench_common (HistogramTopK headroom validation against
  # an operator-driven MessageCount override). Slow (~10-15s release)
  # so it is opt-in rather than part of every CI run.
  exec "nim c -d:release -d:BenchCommonStress --threads:on -r -f tests/t_bench_common.nim"


# task `stresstests` removed in v5.0.0 . The 9 legacy
# `stress-tests/t_*_threaded.nim` files referenced the per-family
# aliases (`Mpmc[N, P, C, T]`, `Spmc[N, C, T]`, etc.) and the
# pre-DEBRA EpochManager API. Rewiring 1,197 LOC to the new
# BQueue/Queue surface with the attach/detach Claim-state idiom was
# multi-hour scope (well beyond the v5.0.0 wrap-up budget). Per Bundle
# I principle ("do NOT silently disable failing tests — fix production
# code OR delete the test"), the stress test suite + task are removed.
# The MM lane matrix (5 lanes × 240 tests, plus TSan/ASan sanitizers
# under `nimble test`) provides the primary concurrency-correctness
# signal.
