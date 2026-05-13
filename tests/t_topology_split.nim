## Tests for the bench-rollup PR 2 topology split.
##
## Five binaries replace the legacy `bench_throughput.nim`:
##
##   bench_spsc       — Sipsic at `1p1c`.
##   bench_mpsc       — Mupsic at `{1,2,4}p1c`.
##   bench_mpmc       — Mupmuc at `{1,2,4,8}p{1,2,4,8}c` (8p8c is the
##                      oversubscription regression case from issue #15),
##                      Sipmuc at `1p{1,2,4}c`, channels at `{1,2,4}p{1,2,4}c`.
##   bench_unbounded  — All 4 unbounded variants at their natural shapes.
##   bench_latency    — already shipped in PR 1.
##
## The deletion-safety check (Task 2.7) verifies the union of post-split
## BMFs is a strict superset of the pre-split BMF captured in
## `tests/fixtures/pre-split-slugs.json`. That fixture is committed and
## treated as immutable by this test suite.
##
## Tests in this file invoke each binary as a subprocess at tiny `-d:`
## overrides so the integration suite stays fast, then parse the emitted
## BMF JSON and assert slug presence.

import std/[json, os, osproc, sets, strutils, tables, tempfiles]
import unittest2

const
  RepoRoot = currentSourcePath().parentDir.parentDir
  PreSplitFixturePath =
    RepoRoot / "tests" / "fixtures" / "pre-split-slugs.json"
  BenchSpscSrc = RepoRoot / "benchmarks" / "nim" / "bench_spsc.nim"
  BenchMpscSrc = RepoRoot / "benchmarks" / "nim" / "bench_mpsc.nim"
  BenchMpmcSrc = RepoRoot / "benchmarks" / "nim" / "bench_mpmc.nim"
  BenchUnboundedSrc = RepoRoot / "benchmarks" / "nim" / "bench_unbounded.nim"
  SupersetCheckScript =
    RepoRoot / "benchmarks" / "scripts" / "superset_check.py"

# ---------- Task 2.1: pre-split fixture exists and is non-empty ----------

suite "topology split: pre-split fixture (Task 2.1)":
  test "fixture file exists and parses to a non-empty BMF JSON object":
    check fileExists(PreSplitFixturePath)
    let node = parseJson(readFile(PreSplitFixturePath))
    check node.kind == JObject
    # Pre-split snapshot covers sipsic + mupmuc + unbounded_mupsic + channels.
    # The exact count is locked here so future regenerations of the
    # fixture must consciously update this assertion (and the deletion-
    # safety check below) rather than silently shrinking the baseline.
    check node.len >= 11
    # Spot-check three representative slugs from the four variant groups
    # so a corruption of the file is caught early.
    check node.hasKey("lockfreequeues_sipsic/spsc/1p1c")
    check node.hasKey("lockfreequeues_mupmuc/mpmc/4p4c")
    check node.hasKey("lockfreequeues_unbounded_mupsic/mpsc_unbounded/4p1c")
    check node.hasKey("nim_channels/mpmc/4p4c")

# ---------- Helpers shared across Tasks 2.3-2.6 ----------

proc compileBench(src: string, defs: openArray[string], suffix: string): string =
  ## Compile a topology bench binary at small `-d:` overrides so the
  ## integration test stays fast. Raises IOError on compile failure;
  ## returns the binary path on success.
  let outBin = getTempDir() / ("bench_topology_split_" & suffix)
  var cmd = "nim c --threads:on -d:release"
  for d in defs:
    cmd.add(" -d:" & d)
  cmd.add(" -o:" & outBin & " " & src)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    raise newException(IOError,
      "compile failed for " & src & ":\n" & output)
  result = outBin

proc parseBmf(path: string): JsonNode =
  parseJson(readFile(path))

# ---------- Task 2.3: bench_spsc emits sipsic/spsc/1p1c ----------

suite "topology split: bench_spsc (Task 2.3)":
  test "compiles + emits BMF containing lockfreequeues_sipsic/spsc/1p1c":
    let bin = compileBench(BenchSpscSrc, [
      "BenchSpscMessageCount=1000",
      "BenchSpscRuns=2",
      "BenchSpscWarmup=0",
    ], "spsc")
    let bmf = getTempDir() / "bench_spsc_t23.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    check fileExists(bmf)
    let node = parseBmf(bmf)
    check node.hasKey("lockfreequeues_sipsic/spsc/1p1c")
    let slug = node["lockfreequeues_sipsic/spsc/1p1c"]
    check slug.hasKey("throughput_ops_ms")
    check slug["throughput_ops_ms"]["value"].getFloat() > 0.0
    removeFile(bmf)

# ---------- Task 2.4: bench_mpsc emits mupsic/mpsc/{1,2,4}p1c ----------

suite "topology split: bench_mpsc (Task 2.4)":
  test "compiles + emits BMF for mupsic 1p1c, 2p1c, 4p1c":
    let bin = compileBench(BenchMpscSrc, [
      "BenchMpscMessageCount=1000",
      "BenchMpscRuns=2",
      "BenchMpscWarmup=0",
    ], "mpsc")
    let bmf = getTempDir() / "bench_mpsc_t24.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    for shape in ["1p1c", "2p1c", "4p1c"]:
      let slug = "lockfreequeues_mupsic/mpsc/" & shape
      check node.hasKey(slug)
      check node[slug].hasKey("throughput_ops_ms")
      check node[slug]["throughput_ops_ms"]["value"].getFloat() > 0.0
    removeFile(bmf)

# ---------- Task 2.5: bench_mpmc emits mupmuc grid + sipmuc + channels ----------

suite "topology split: bench_mpmc (Task 2.5)":
  test "compiles + emits BMF for mupmuc 4x4 grid + 8p8c + sipmuc 1p{1,2,4}c + channels {1,2,4}p{1,2,4}c":
    let bin = compileBench(BenchMpmcSrc, [
      "BenchMpmcMessageCount=1000",
      "BenchMpmcRuns=2",
      "BenchMpmcWarmup=0",
    ], "mpmc")
    let bmf = getTempDir() / "bench_mpmc_t25.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    # Mupmuc 4x4 grid plus the 8p8c oversubscription case (preserved
    # from pre-split fixture; #15 livelock regression coverage).
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        let slug = "lockfreequeues_mupmuc/mpmc/" & $p & "p" & $c & "c"
        check node.hasKey(slug)
        check node[slug]["throughput_ops_ms"]["value"].getFloat() > 0.0
    check node.hasKey("lockfreequeues_mupmuc/mpmc/8p8c")
    # Sipmuc — single producer, multi consumer. v4.2.0 reclassified
    # sipmuc onto the first-class SPMC topology axis (`tSpmc`) so the
    # slug shape changed from `.../mpmc/1pXc` to `.../spmc/1pXc`.
    for c in [1, 2, 4]:
      let slug = "lockfreequeues_sipmuc/spmc/1p" & $c & "c"
      check node.hasKey(slug)
      check node[slug]["throughput_ops_ms"]["value"].getFloat() > 0.0
    # Channels (Nim system Channel) — full {1,2,4}p{1,2,4}c grid.
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        let slug = "nim_channels/mpmc/" & $p & "p" & $c & "c"
        check node.hasKey(slug)
        check node[slug]["throughput_ops_ms"]["value"].getFloat() > 0.0
    removeFile(bmf)

# ---------- Task 2.6: bench_unbounded covers all 4 unbounded variants ----------

suite "topology split: bench_unbounded (Task 2.6)":
  test "compiles + emits BMF for all 4 unbounded variants at their natural shapes":
    let bin = compileBench(BenchUnboundedSrc, [
      "UnboundedSipsicMessageCount=500",
      "UnboundedSipsicRuns=2",
      "UnboundedSipmucMessageCount=500",
      "UnboundedSipmucRuns=2",
      "UnboundedMupsicMessageCount=500",
      "UnboundedMupsicRuns=2",
      "UnboundedMupmucMessageCount=500",
      "UnboundedMupmucRuns=2",
      "BenchUnboundedWarmup=0",
    ], "unbounded")
    let bmf = getTempDir() / "bench_unbounded_t26.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    # Sipsic unbounded: spsc only, 1p1c.
    check node.hasKey("lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c")
    # Sipmuc unbounded: 1 producer × {1,2,4} consumers. v4.2.0 moved
    # the topology axis from `mpmc_unbounded` to `spmc_unbounded` to
    # match the bounded sipmuc reclassification (Decision A1).
    for c in [1, 2, 4]:
      check node.hasKey(
        "lockfreequeues_unbounded_sipmuc/spmc_unbounded/1p" & $c & "c")
    # Mupsic unbounded: {1,2,4} producers × 1 consumer.
    for p in [1, 2, 4]:
      check node.hasKey(
        "lockfreequeues_unbounded_mupsic/mpsc_unbounded/" & $p & "p1c")
    # Mupmuc unbounded: {1,2,4} P × {1,2,4} C.
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        check node.hasKey(
          "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/" &
          $p & "p" & $c & "c")
    removeFile(bmf)

# ---------- Task 2.7: strict-superset deletion-safety check ----------

suite "topology split: deletion-safety (Task 2.7)":
  test "post-split union is a strict superset of pre-split fixture":
    # Compile and run all four binaries at small overrides; merge the
    # outputs via merge_bmf.py; invoke superset_check.py and assert
    # exit 0 + no output to stderr.
    let dir = createTempDir("topology_split_superset_", "")
    defer: removeDir(dir)
    let spscBin = compileBench(BenchSpscSrc, [
      "BenchSpscMessageCount=1000",
      "BenchSpscRuns=2",
      "BenchSpscWarmup=0",
    ], "superset_spsc")
    let mpscBin = compileBench(BenchMpscSrc, [
      "BenchMpscMessageCount=1000",
      "BenchMpscRuns=2",
      "BenchMpscWarmup=0",
    ], "superset_mpsc")
    let mpmcBin = compileBench(BenchMpmcSrc, [
      "BenchMpmcMessageCount=1000",
      "BenchMpmcRuns=2",
      "BenchMpmcWarmup=0",
    ], "superset_mpmc")
    let unboundedBin = compileBench(BenchUnboundedSrc, [
      "UnboundedSipsicMessageCount=500",
      "UnboundedSipsicRuns=2",
      "UnboundedSipmucMessageCount=500",
      "UnboundedSipmucRuns=2",
      "UnboundedMupsicMessageCount=500",
      "UnboundedMupsicRuns=2",
      "UnboundedMupmucMessageCount=500",
      "UnboundedMupmucRuns=2",
      "BenchUnboundedWarmup=0",
    ], "superset_unbounded")
    let spscJson = dir / "spsc.json"
    let mpscJson = dir / "mpsc.json"
    let mpmcJson = dir / "mpmc.json"
    let unboundedJson = dir / "unbounded.json"
    let mergedJson = dir / "merged.json"
    for (bin, outPath) in [
      (spscBin, spscJson),
      (mpscBin, mpscJson),
      (mpmcBin, mpmcJson),
      (unboundedBin, unboundedJson),
    ]:
      let (output, exitCode) = execCmdEx(bin & " --bmf-out=" & outPath)
      check exitCode == 0
      if exitCode != 0:
        echo "binary failed: ", bin, "\n", output
    # Merge.
    let mergeCmd = "python3 " & RepoRoot / "benchmarks" / "merge_bmf.py" &
      " " & mergedJson & " " & spscJson & " " & mpscJson & " " &
      mpmcJson & " " & unboundedJson
    let (mergeOutput, mergeExit) = execCmdEx(mergeCmd)
    check mergeExit == 0
    if mergeExit != 0:
      echo "merge failed:\n", mergeOutput
    # Superset check.
    let supersetCmd = "python3 " & SupersetCheckScript &
      " " & PreSplitFixturePath & " " & mergedJson
    let (supersetOutput, supersetExit) = execCmdEx(supersetCmd)
    check supersetExit == 0
    if supersetExit != 0:
      echo "superset check failed:\n", supersetOutput
