import os

# Package
version        = "3.1.0"
author         = "Elijah Shaw-Rutschman"
description    = "Lock-free queue implementations for Nim."
license        = "MIT"
srcDir         = "src"
entryPoints    = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.0.0"
requires "unittest2"
requires "typestates"
requires "debra"

# Tasks
task test, "Runs the test suite":
  # C
  exec "nim c --threads:on -r -f tests/test.nim"

  # C++
  exec "nim cpp --threads:on -r -f tests/test.nim"

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
  exec "nim c -d:release --threads:on benchmarks/nim/bench_main.nim"
  exec "benchmarks/nim/bench_main --runs=10 -o=benchmarks/results/latest.json"


task stresstests, "Runs the stress test suite (multi-threaded)":
  # C
  exec "nim c --path:src --threads:on -r -f stress-tests/stress_test.nim"

  # C++
  exec "nim cpp --path:src --threads:on -r -f stress-tests/stress_test.nim"

  if getEnv("SANITIZE_THREADS") != "no":
    # C (with thread sanitization)
    exec "nim c --cc:clang --mm:atomicArc --path:src --passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" --threads:on -r -f stress-tests/stress_test.nim"

  if getEnv("SANITIZE_ADDRESS") != "no":
    # C (with address sanitization)
    exec "nim c --cc:clang --path:src --passC:\"-fsanitize=address\" --passL:\"-fsanitize=address\" --threads:on -r -f stress-tests/stress_test.nim"
