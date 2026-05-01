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

# ---------- Task 1.2: --bmf-out integration ----------

proc compileBenchLatency(extraDefs: openArray[string], suffix: string): string =
  ## Compile bench_latency.nim with extra -d: defines, return path to the
  ## resulting binary. Compiles in release mode for realistic timing but
  ## with tiny message counts so the integration test stays fast.
  let outBin = getTempDir() / ("bench_latency_t" & suffix)
  var cmd = "nim c --threads:on -d:release"
  for d in extraDefs:
    cmd.add(" -d:" & d)
  cmd.add(" -o:" & outBin & " " & BenchLatencySrc)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    raise newException(IOError, "bench_latency compile failed:\n" & output)
  result = outBin

suite "bench_latency --bmf-out integration (Task 1.2)":
  test "sipsic variant emits latency_p50_ns / latency_p99_ns on expected slug":
    # Override message count + runs to keep the integration run under ~5s.
    let bin = compileBenchLatency(@[
      "BenchLatencyMessageCount=200",
      "BenchLatencyRuns=2",
    ], suffix = "12_sipsic")
    let bmfPath = getTempDir() / "bench_latency_t12_sipsic.json"
    if fileExists(bmfPath): removeFile(bmfPath)
    let cmd = bin & " --bmf-out=" & bmfPath & " sipsic"
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    check fileExists(bmfPath)
    let node = parseJson(readFile(bmfPath))
    # Expected slug per design 2.2 / table at design line 357.
    let slug = "lockfreequeues_sipsic/spsc/1p1c"
    check node.hasKey(slug)
    let s = node[slug]
    check s.hasKey("latency_p50_ns")
    check s.hasKey("latency_p95_ns")
    check s.hasKey("latency_p99_ns")
    check s["latency_p50_ns"]["value"].getFloat() > 0.0
    check s["latency_p99_ns"]["value"].getFloat() >= s["latency_p50_ns"]["value"].getFloat()
    # Stdout text output preserved (acceptance: positional CLI behavior).
    check output.contains("Sipsic") or output.contains("sipsic")
    removeFile(bmfPath)

  test "all four bounded variants emit latency_p50_ns / latency_p99_ns":
    # Per impl plan Track 1 Acceptance Criteria: BMF JSON contains
    # latency_p50_ns and latency_p99_ns for sipsic / sipmuc / mupsic /
    # mupmuc on the 1p1c smoke shape.
    let bin = compileBenchLatency(@[
      "BenchLatencyMessageCount=200",
      "BenchLatencyRuns=2",
    ], suffix = "12_all4")
    let bmfPath = getTempDir() / "bench_latency_t12_all4.json"
    if fileExists(bmfPath): removeFile(bmfPath)
    let cmd = bin & " --bmf-out=" & bmfPath &
              " sipsic mupmuc sipmuc mupsic"
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseJson(readFile(bmfPath))
    let expectedSlugs = @[
      "lockfreequeues_sipsic/spsc/1p1c",
      "lockfreequeues_sipmuc/mpmc/1p1c",
      "lockfreequeues_mupsic/mpsc/1p1c",
      "lockfreequeues_mupmuc/mpmc/1p1c",
    ]
    for slug in expectedSlugs:
      check node.hasKey(slug)
      check node[slug].hasKey("latency_p50_ns")
      check node[slug].hasKey("latency_p99_ns")
    removeFile(bmfPath)

  test "unknown variant exits 1":
    let bin = compileBenchLatency(@[
      "BenchLatencyMessageCount=200",
      "BenchLatencyRuns=2",
    ], suffix = "12_unknown")
    let cmd = bin & " bogus_variant"
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 1
