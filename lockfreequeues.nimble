import os

# Package
version        = "4.1.0"
author         = "Elijah Shaw-Rutschman"
description    = "Lock-free queue implementations for Nim."
license        = "MIT"
srcDir         = "src"
entryPoints    = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.2.0"
requires "unittest2"
requires "typestates >= 0.9.3"
requires "debra >= 0.8.0"

# Tasks
task should_fail, "Verifies compile-fail negative controls (Doc C §6.3)":
  # Driver iterates the 5-case table and runs `nim c --compileOnly` per
  # case, asserting expected exit + pinned substring. Ported from
  # nim-debra 0.8.0's `tests/should_fail/runner.nim` harness.
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"

task test, "Runs the test suite":
  # Compile-fail negative controls (Doc C §6.3). Runs first so a
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

  # Test with lock-free enforcement (ensures no spinlock fallback)
  exec "nim c --mm:arc -d:nimEnforceLockFreeAtomics --threads:on -r -f tests/test.nim"
  exec "nim c --mm:orc -d:nimEnforceLockFreeAtomics --threads:on -r -f tests/test.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # C (with thread sanitization, requires atomicArc for thread-safe refcounting)
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f tests/test.nim"

  if getEnv("SANITIZE_ADDRESS") != "no":
    # C (with address sanitization)
    exec "nim c --cc:clang --passC:\"-fsanitize=address\" --passL:\"-fsanitize=address\" --threads:on -r -f tests/test.nim"


task examples, "Runs the examples":
  # Bounded queue examples
  exec "nim c --threads:on -r -f examples/sipsic.nim"
  exec "nim c --threads:on -r -f examples/sipmuc.nim"
  exec "nim c --threads:on -r -f examples/mupsic.nim"
  exec "nim c --threads:on -r -f examples/mupmuc.nim"
  # Advanced examples
  exec "nim c --threads:on -r -f examples/audio_buffer.nim"
  exec "nim c --threads:on -r -f examples/task_fanout.nim"
  exec "nim c --threads:on -r -f examples/event_collector.nim"
  exec "nim c --threads:on -r -f examples/job_scheduler.nim"

task benchmarks, "Runs the benchmark suite":
  # PR 2 (bench-rollup) replaced bench_throughput.nim with topology-
  # split binaries. v5.0.0 B3 further split the MPMC binary into a
  # per-family pair (bench_mpmc_mupmuc + bench_mpmc_sipmuc) to remove
  # cross-family iCache contention; v5.0.0 3.3.9-D applied the same
  # mitigation to the unbounded binary, fanning it out into four
  # per-family binaries (bench_unbounded_{sipsic,sipmuc,mupsic,mupmuc}).
  # See the bench_mpmc_*.nim and bench_unbounded_*.nim headers for the
  # diagnostic that motivated each split. Each binary emits its own
  # Bencher Metric Format JSON fragment; merge_bmf.py unions them into
  # one final file. Binaries land in `.tmp/` per the project nim.cfg
  # (`--outdir:.tmp`).
  mkDir "benchmarks/results"
  for binName in [
    "bench_spsc", "bench_mpsc",
    "bench_mpmc_mupmuc", "bench_mpmc_sipmuc",
    "bench_unbounded_sipsic", "bench_unbounded_sipmuc",
    "bench_unbounded_mupsic", "bench_unbounded_mupmuc",
    "bench_latency",
  ]:
    exec "nim c -d:release --threads:on benchmarks/nim/" & binName & ".nim"
    exec ".tmp/" & binName & " --bmf-out=benchmarks/results/" & binName & ".json"
  # Union the per-binary fragments. Exits 1 on (slug, measure) collisions.
  exec "python3 benchmarks/merge_bmf.py benchmarks/results/latest.json " &
       "benchmarks/results/bench_spsc.json " &
       "benchmarks/results/bench_mpsc.json " &
       "benchmarks/results/bench_mpmc_mupmuc.json " &
       "benchmarks/results/bench_mpmc_sipmuc.json " &
       "benchmarks/results/bench_unbounded_sipsic.json " &
       "benchmarks/results/bench_unbounded_sipmuc.json " &
       "benchmarks/results/bench_unbounded_mupsic.json " &
       "benchmarks/results/bench_unbounded_mupmuc.json " &
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


task benchteststress, "Runs the bench harness test suite including 3.3M-sample stress shapes":
  # Like `benchtests` but enables the gated 3.3M-sample p999 stress
  # shape in t_bench_common (HistogramTopK headroom validation against
  # an operator-driven MessageCount override). Slow (~10-15s release)
  # so it is opt-in rather than part of every CI run.
  exec "nim c -d:release -d:BenchCommonStress --threads:on -r -f tests/t_bench_common.nim"


task stresstests, "Runs the stress test suite (multi-threaded)":
  # C with default MM (orc)
  exec "nim c --path:src --threads:on -r -f stress-tests/stress_test.nim"

  # C++
  exec "nim cpp --path:src --threads:on -r -f stress-tests/stress_test.nim"

  # Test with different memory managers
  exec "nim c --mm:arc --path:src --threads:on -r -f stress-tests/stress_test.nim"
  exec "nim c --mm:refc --path:src --threads:on -r -f stress-tests/stress_test.nim"

  # Test with lock-free enforcement
  exec "nim c --mm:arc -d:nimEnforceLockFreeAtomics --path:src --threads:on -r -f stress-tests/stress_test.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # C (with thread sanitization)
    exec "nim c --cc:clang --mm:atomicArc --path:src --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f stress-tests/stress_test.nim"

  if getEnv("SANITIZE_ADDRESS") != "no":
    # C (with address sanitization)
    exec "nim c --cc:clang --path:src --passC:\"-fsanitize=address\" --passL:\"-fsanitize=address\" --threads:on -r -f stress-tests/stress_test.nim"
