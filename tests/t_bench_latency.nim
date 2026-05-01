## Tests for benchmarks/nim/bench_latency.nim — the latency bench binary.
##
## Track 1 (PR 1) covers: per-binary intdefines (Task 1.1), --bmf-out
## emission via runLatencyHarness (Task 1.2), and multi-measure-per-slug
## merge with throughput (Task 1.5).
##
## The bench binary is invoked as a subprocess in the integration tests
## (Tasks 1.2 / 1.5); compile-time intdefine assertions (Task 1.1) live
## in the binary itself behind a `BenchLatencyTestCompileTime` flag and
## are exercised from a tiny dedicated build invocation here.

import std/[json, os, osproc, strutils, tempfiles]
import unittest2

const
  RepoRoot = currentSourcePath().parentDir.parentDir
  BenchLatencySrc = RepoRoot / "benchmarks" / "nim" / "bench_latency.nim"

# ---------- Task 1.1: intdefine defaults + override ----------

suite "bench_latency intdefines (Task 1.1)":
  test "defaults: BenchLatencyRuns == 33, BenchLatencyMessageCount == 100_000":
    # Compile bench_latency.nim with -d:BenchLatencyTestCompileTime=1.
    # The binary, when this define is set, runs a `static` block that
    # asserts the two intdefine defaults; if they are wrong, compilation
    # fails with the static assert message.
    let outBin = getTempDir() / "bench_latency_t11_defaults"
    let cmd = "nim c --threads:on -d:release -d:BenchLatencyTestCompileTime=1 " &
              "-o:" & outBin & " " & BenchLatencySrc
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    if exitCode != 0:
      echo "compile output:\n", output

  test "overrides: -d:BenchLatencyRuns=2 -d:BenchLatencyMessageCount=1000 take effect":
    # Compile with overrides + a different test flag that checks the
    # overridden values rather than the defaults.
    let outBin = getTempDir() / "bench_latency_t11_overrides"
    let cmd = "nim c --threads:on -d:release " &
              "-d:BenchLatencyTestCompileTimeOverrides=1 " &
              "-d:BenchLatencyRuns=2 -d:BenchLatencyMessageCount=1000 " &
              "-o:" & outBin & " " & BenchLatencySrc
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    if exitCode != 0:
      echo "compile output:\n", output
