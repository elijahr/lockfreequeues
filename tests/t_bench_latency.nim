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

proc newTestWorkspace(prefix: string): string =
  ## Allocate a private workspace dir for one test. Each test that
  ## compiles a bench_latency binary or writes a BMF file uses this so:
  ##   1. parallel runs (or repeated runs in the same shell) cannot
  ##      collide on a static `/tmp/bench_latency_t11_*` filename, and
  ##   2. compiled binaries don't accumulate in the system temp dir.
  ## The caller is responsible for `removeDir` (typically via `defer`).
  ## `prefix` is a per-test stem that matches the original static suffix
  ## so test failure messages stay legible.
  result = createTempDir("bench_latency_" & prefix & "_", "")

# ---------- Task 1.1: intdefine defaults + override ----------

suite "bench_latency intdefines (Task 1.1)":
  test "defaults: BenchLatencyRuns == 33, BenchLatencyMessageCount == 100_000":
    # Compile bench_latency.nim with -d:BenchLatencyTestCompileTime=1.
    # The binary, when this define is set, runs a `static` block that
    # asserts the two intdefine defaults; if they are wrong, compilation
    # fails with the static assert message.
    let dir = newTestWorkspace("t11_defaults")
    defer: removeDir(dir)
    let outBin = dir / ("bench_latency" & ExeExt)
    let cmd = "nim c --threads:on -d:release -d:BenchLatencyTestCompileTime=1 " &
              "-o:" & outBin & " " & BenchLatencySrc
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    if exitCode != 0:
      echo "compile output:\n", output

  test "overrides: -d:BenchLatencyRuns=2 -d:BenchLatencyMessageCount=1000 take effect":
    # Compile with overrides + a different test flag that checks the
    # overridden values rather than the defaults.
    let dir = newTestWorkspace("t11_overrides")
    defer: removeDir(dir)
    let outBin = dir / ("bench_latency" & ExeExt)
    let cmd = "nim c --threads:on -d:release " &
              "-d:BenchLatencyTestCompileTimeOverrides=1 " &
              "-d:BenchLatencyRuns=2 -d:BenchLatencyMessageCount=1000 " &
              "-o:" & outBin & " " & BenchLatencySrc
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    if exitCode != 0:
      echo "compile output:\n", output

# ---------- Task 1.2: --bmf-out integration ----------

proc compileBenchLatency(
    extraDefs: openArray[string], dir: string
): string =
  ## Compile bench_latency.nim with extra -d: defines into `dir` and
  ## return the binary path. Caller owns `dir` and must remove it.
  ## Compiles in release mode for realistic timing but with tiny
  ## message counts so the integration test stays fast.
  let outBin = dir / ("bench_latency" & ExeExt)
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
    let dir = newTestWorkspace("t12_sipsic")
    defer: removeDir(dir)
    let bin = compileBenchLatency(@[
      "BenchLatencyMessageCount=200",
      "BenchLatencyRuns=2",
    ], dir = dir)
    let bmfPath = dir / "bench_latency.json"
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

  test "all four bounded variants emit latency_p50_ns / latency_p99_ns":
    # Per impl plan Track 1 Acceptance Criteria: BMF JSON contains
    # latency_p50_ns and latency_p99_ns for sipsic / sipmuc / mupsic /
    # mupmuc on the 1p1c smoke shape.
    let dir = newTestWorkspace("t12_all4")
    defer: removeDir(dir)
    let bin = compileBenchLatency(@[
      "BenchLatencyMessageCount=200",
      "BenchLatencyRuns=2",
    ], dir = dir)
    let bmfPath = dir / "bench_latency.json"
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

  test "unknown variant exits 1":
    let dir = newTestWorkspace("t12_unknown")
    defer: removeDir(dir)
    let bin = compileBenchLatency(@[
      "BenchLatencyMessageCount=200",
      "BenchLatencyRuns=2",
    ], dir = dir)
    let cmd = bin & " bogus_variant"
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 1

# ---------- Task 1.5: multi-measure-per-slug merge ----------
#
# Validates the end-to-end shape that Track 1 ships: a single slug
# carries BOTH `throughput_ops_ms` (from bench_throughput's BMF
# fragment) and `latency_p50_ns` / `latency_p99_ns` (from bench_latency)
# AFTER `merge_bmf.py` unions the two fragments. Production CI does this
# with real bench output; the test uses two synthetic fragments so it
# stays fast and deterministic.

const MergeBmfPath = RepoRoot / "benchmarks" / "merge_bmf.py"

suite "bench_latency multi-measure-per-slug merge (Task 1.5)":
  test "merge_bmf.py unions throughput + latency on shared slug":
    let dir = createTempDir("bench_latency_t15_", "")
    defer: removeDir(dir)
    let throughputPath = dir / "throughput.json"
    let latencyPath = dir / "latency.json"
    let mergedPath = dir / "merged.json"
    let slug = "lockfreequeues_sipsic/spsc/1p1c"

    # Synthetic throughput fragment.
    writeFile(throughputPath,
      """{
  "lockfreequeues_sipsic/spsc/1p1c": {
    "throughput_ops_ms": {
      "value": 1234.5,
      "lower_value": 1200.0,
      "upper_value": 1270.0
    }
  }
}""")
    # Synthetic latency fragment on the SAME slug, distinct measures.
    writeFile(latencyPath,
      """{
  "lockfreequeues_sipsic/spsc/1p1c": {
    "latency_p50_ns": { "value": 250.0 },
    "latency_p99_ns": { "value": 875.0 }
  }
}""")

    let cmd = "python3 " & MergeBmfPath & " " & mergedPath &
              " " & throughputPath & " " & latencyPath
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    if exitCode != 0:
      echo "merge stdout/stderr:\n", output
    check fileExists(mergedPath)

    let node = parseJson(readFile(mergedPath))
    check node.hasKey(slug)
    let s = node[slug]
    # All three measures from BOTH fragments must coexist on the shared slug.
    check s.hasKey("throughput_ops_ms")
    check s.hasKey("latency_p50_ns")
    check s.hasKey("latency_p99_ns")
    check s["throughput_ops_ms"]["value"].getFloat() == 1234.5
    check s["latency_p50_ns"]["value"].getFloat() == 250.0
    check s["latency_p99_ns"]["value"].getFloat() == 875.0

  test "merge_bmf.py exits 1 on collision when same measure key in both inputs":
    # Sanity: the per-slug union union semantics are NOT a free-for-all;
    # ensure the collision guard from PR 0 Task 0.7 still fires when the
    # latency fragment accidentally re-declares throughput_ops_ms on the
    # same slug. This guards against silent overwrites that would erase
    # one of the measures.
    let dir = createTempDir("bench_latency_t15_collide_", "")
    defer: removeDir(dir)
    let aPath = dir / "a.json"
    let bPath = dir / "b.json"
    let mergedPath = dir / "merged.json"

    writeFile(aPath,
      """{
  "lockfreequeues_sipsic/spsc/1p1c": {
    "throughput_ops_ms": { "value": 100.0 }
  }
}""")
    writeFile(bPath,
      """{
  "lockfreequeues_sipsic/spsc/1p1c": {
    "throughput_ops_ms": { "value": 200.0 }
  }
}""")
    let cmd = "python3 " & MergeBmfPath & " " & mergedPath &
              " " & aPath & " " & bPath
    let (output, exitCode) = execCmdEx(cmd)
    check exitCode == 1
    check output.contains("collision")
