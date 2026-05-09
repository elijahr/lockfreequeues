import os

# Package
version        = "4.2.0"
author         = "Elijah Shaw-Rutschman"
description    = "Lock-free queue implementations for Nim."
license        = "MIT"
srcDir         = "src"
entryPoints    = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.2.10"
requires "unittest2"
requires "typestates >= 0.8.0"
requires "debra >= 0.7.3"

# Tasks
task checkConsumerHeadsAbsent, "Verify consumerHeads is absent from src/":
  # v4.3 Task 6 invariant gate: the SPMC `consumerHeads` array was dead
  # (allocated/zeroed but never read) and was deleted in Task 6. This
  # gate fails CI loudly if any future change reintroduces the field.
  exec "sh -c 'rg --quiet consumerHeads src/lockfreequeues/ && (echo \"FAIL: consumerHeads found\" && exit 1) || echo \"OK: consumerHeads absent\"'"


task checkBulkOutsidePin, "Verify bulk loops are not nested inside withPin blocks":
  # R6 invariant gate (per v4.3 design §2.4): bulk variants of push/pop on
  # unbounded queues MUST run OUTSIDE the producer/consumer's `withPin:`
  # block so each iteration acquires its own pin. A bulk loop nested inside
  # `withPin:` would extend the pin epoch arbitrarily, blocking DEBRA
  # reclamation. The regex looks at 5 lines after every `withPin:` site;
  # if any single-letter loop variable (`item` or `i`) appears in that
  # window, fail loudly. This is a CI-enforced gate introduced with the
  # MPSC facade migration (Task 5).
  exec "sh -c 'rg -A 5 \"withPin:\" src/lockfreequeues/unbounded_*.nim | rg -q \"for (item|i) in\" && (echo \"FAIL: bulk loop inside withPin\" && exit 1) || echo \"OK: bulk-outside-pin invariant holds\"'"


task stresstest, "Run intermittent-bug-class stress tests":
  # Hammers `tests/t_unbounded_sipmuc_threaded_stress.nim` with the
  # ``-d:stress`` switch flipped on (50× outer loop on the SPMC
  # high-segment-turnover scenario). Atomic-arc + threads:on mirrors
  # the configuration that historically surfaced the SPMC end-of-run
  # livelock. Add ``-d:stressDebug`` for the heartbeat + per-1000-item
  # checkpoint logging when triaging a hang via
  # ``scripts/run_with_hang_sample.py``.
  exec "nim c --mm:atomicArc --threads:on -d:stress " &
       "-r tests/t_unbounded_sipmuc_threaded_stress.nim"


task test, "Runs the test suite":
  # v4.3 Task 6 invariant gate (consumerHeads absent) — runs FIRST so a
  # regression short-circuits the long MM-matrix test pass.
  exec "nimble checkConsumerHeadsAbsent"

  # R6 invariant gate (bulk-outside-pin) — runs early so a violation
  # short-circuits the long MM-matrix test pass.
  exec "nimble checkBulkOutsidePin"

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
  # PR 2 (bench-rollup) replaced bench_throughput.nim with five
  # topology-split binaries. Each emits its own Bencher Metric Format
  # JSON fragment; merge_bmf.py unions them into one final file.
  # Binaries land in `.tmp/` per the project nim.cfg (`--outdir:.tmp`).
  mkDir "benchmarks/results"
  for binName in [
    "bench_spsc", "bench_mpsc", "bench_mpmc",
    "bench_unbounded", "bench_latency",
  ]:
    exec "nim c -d:release --threads:on benchmarks/nim/" & binName & ".nim"
    exec ".tmp/" & binName & " --bmf-out=benchmarks/results/" & binName & ".json"
  # Union the per-binary fragments. Exits 1 on (slug, measure) collisions.
  exec "python3 benchmarks/merge_bmf.py benchmarks/results/latest.json " &
       "benchmarks/results/bench_spsc.json " &
       "benchmarks/results/bench_mpsc.json " &
       "benchmarks/results/bench_mpmc.json " &
       "benchmarks/results/bench_unbounded.json " &
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
  exec "nim c --mm:refc --threads:on -r -f tests/t_bench_common.nim"
  exec "nim c --threads:on -r -f tests/t_bench_latency.nim"
  exec "nim c --threads:on -r -f tests/t_bench_adapters.nim"
  exec "nim c --threads:on -r -f tests/t_topology_split.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # Mirrors `task test`'s TSAN clause so future regressions on the
    # bench harness (e.g. a non-atomic shared field on a SmokeAdapter
    # variant) are caught in CI rather than during a manual TSAN run.
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f tests/t_bench_common.nim"
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f tests/t_bench_latency.nim"
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f tests/t_bench_adapters.nim"
    exec "nim c --cc:clang --mm:atomicArc --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f tests/t_topology_split.nim"


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
