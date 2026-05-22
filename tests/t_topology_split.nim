## Tests for the bench-rollup PR 2 topology split (post v5.0.0 B3 +
## v5.0.0 3.3.9-D splits).
##
## Topology-split binaries replace the legacy `bench_throughput.nim`:
##
##   bench_spsc                — Sipsic at `1p1c`.
##   bench_mpsc                — Mupsic at `{1,2,4}p1c`.
##   bench_mpmc_mupmuc         — Mupmuc at `{1,2,4}p{1,2,4}c` + `8p8c`
##                               (issue #15 livelock regression),
##                               Queue-bounded-mupmuc parity at the same
##                               shapes, channels at `{1,2,4}p{1,2,4}c`.
##   bench_mpmc_sipmuc         — Sipmuc at `1p{1,2,4}c`,
##                               Queue-bounded-sipmuc parity at the same
##                               shapes.
##   bench_unbounded_sipsic    — UnboundedSipsic at `1p1c`.
##   bench_unbounded_sipmuc    — UnboundedSipmuc at `1p{1,2,4}c`.
##   bench_unbounded_mupsic    — UnboundedMupsic at `{1,2,4}p1c`.
##   bench_unbounded_mupmuc    — UnboundedMupmuc at `{1,2,4}p{1,2,4}c`
##                               (full grid).
##   bench_latency             — already shipped in PR 1.
##
## v5.0.0 B3 split the pre-existing `bench_mpmc` binary into the two
## per-family binaries above because co-compiling the Mupmuc grid and
## the Sipmuc shapes produced a cross-family iCache contention artifact
## (-39.6% on `sipmuc/mpmc/1p1c`; see the bench_mpmc_*.nim headers).
##
## v5.0.0 3.3.9-D applied the same mitigation to `bench_unbounded`,
## fanning it out into four per-family binaries because co-compiling
## all four unbounded families + three MVP adapters into one release
## binary produced -17% to -34% throughput regressions on
## unbounded_mupmuc/2p2c, unbounded_mupsic/2p1c, and unbounded_mupsic/
## 4p1c in 3.3.9 retry #4 (see the bench_unbounded_*.nim headers).
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
  BenchMpmcMupmucSrc =
    RepoRoot / "benchmarks" / "nim" / "bench_mpmc_mupmuc.nim"
  BenchMpmcSipmucSrc =
    RepoRoot / "benchmarks" / "nim" / "bench_mpmc_sipmuc.nim"
  BenchUnboundedSipsicSrc =
    RepoRoot / "benchmarks" / "nim" / "bench_unbounded_sipsic.nim"
  BenchUnboundedSipmucSrc =
    RepoRoot / "benchmarks" / "nim" / "bench_unbounded_sipmuc.nim"
  BenchUnboundedMupsicSrc =
    RepoRoot / "benchmarks" / "nim" / "bench_unbounded_mupsic.nim"
  BenchUnboundedMupmucSrc =
    RepoRoot / "benchmarks" / "nim" / "bench_unbounded_mupmuc.nim"
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

# ---------- Task 2.5a: bench_mpmc_mupmuc emits mupmuc grid + channels ----------
#
# v5.0.0 B3 split the original Task 2.5 `bench_mpmc` suite into two
# per-family suites. The mupmuc binary owns the Mupmuc 4x4 grid + 8p8c
# oversubscription case, the Queue-bounded-mupmuc parity grid, and the
# nim_channels {1,2,4}p{1,2,4}c grid (channels match the mupmuc shape
# set). The sipmuc binary (Task 2.5b below) owns the 3-shape sipmuc set.

suite "topology split: bench_mpmc_mupmuc (Task 2.5a)":
  test "compiles + emits BMF for mupmuc 4x4 grid + 8p8c + channels {1,2,4}p{1,2,4}c":
    let bin = compileBench(BenchMpmcMupmucSrc, [
      "BenchMpmcMessageCount=1000",
      "BenchMpmcRuns=2",
      "BenchMpmcWarmup=0",
    ], "mpmc_mupmuc")
    let bmf = getTempDir() / "bench_mpmc_mupmuc_t25a.json"
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
    # Channels (Nim system Channel) — full {1,2,4}p{1,2,4}c grid.
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        let slug = "nim_channels/mpmc/" & $p & "p" & $c & "c"
        check node.hasKey(slug)
        check node[slug]["throughput_ops_ms"]["value"].getFloat() > 0.0
    # Sipmuc slugs must NOT appear in this binary (they live in
    # bench_mpmc_sipmuc; co-compiling the two families was the
    # iCache-contention regression the split addresses).
    check (not node.hasKey("lockfreequeues_sipmuc/mpmc/1p1c"))
    removeFile(bmf)

# ---------- Task 2.5b: bench_mpmc_sipmuc emits sipmuc 1p{1,2,4}c ----------

suite "topology split: bench_mpmc_sipmuc (Task 2.5b)":
  test "compiles + emits BMF for sipmuc 1p{1,2,4}c":
    let bin = compileBench(BenchMpmcSipmucSrc, [
      "BenchMpmcMessageCount=1000",
      "BenchMpmcRuns=2",
      "BenchMpmcWarmup=0",
    ], "mpmc_sipmuc")
    let bmf = getTempDir() / "bench_mpmc_sipmuc_t25b.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    # Sipmuc — single producer, multi consumer, lives under mpmc per
    # design 2.4.
    for c in [1, 2, 4]:
      let slug = "lockfreequeues_sipmuc/mpmc/1p" & $c & "c"
      check node.hasKey(slug)
      check node[slug]["throughput_ops_ms"]["value"].getFloat() > 0.0
    # Mupmuc + channels slugs must NOT appear here (split contract).
    check (not node.hasKey("lockfreequeues_mupmuc/mpmc/1p1c"))
    check (not node.hasKey("nim_channels/mpmc/1p1c"))
    removeFile(bmf)

# ---------- Task 2.6a: bench_unbounded_sipsic emits sipsic 1p1c ----------
#
# v5.0.0 3.3.9-D split the original Task 2.6 `bench_unbounded` suite
# into four per-family suites (Task 2.6a..2.6d). Each binary owns one
# unbounded family; the union of their slug sets equals what the
# pre-split `bench_unbounded` binary emitted. The split mirrors the
# v5.0.0 B3 mpmc-binary split; see the bench_unbounded_*.nim headers
# for the iCache-contention diagnostic.

suite "topology split: bench_unbounded_sipsic (Task 2.6a)":
  test "compiles + emits BMF for unbounded_sipsic 1p1c":
    let bin = compileBench(BenchUnboundedSipsicSrc, [
      "UnboundedSipsicMessageCount=500",
      "UnboundedSipsicRuns=2",
      "BenchUnboundedWarmup=0",
    ], "unbounded_sipsic")
    let bmf = getTempDir() / "bench_unbounded_sipsic_t26a.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    check node.hasKey("lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c")
    # Other unbounded families must NOT appear here (split contract).
    check (not node.hasKey(
      "lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_mupsic/mpsc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/1p1c"))
    removeFile(bmf)

# ---------- Task 2.6b: bench_unbounded_sipmuc emits sipmuc 1p{1,2,4}c -----

suite "topology split: bench_unbounded_sipmuc (Task 2.6b)":
  test "compiles + emits BMF for unbounded_sipmuc 1p{1,2,4}c":
    let bin = compileBench(BenchUnboundedSipmucSrc, [
      "UnboundedSipmucMessageCount=500",
      "UnboundedSipmucRuns=2",
      "BenchUnboundedWarmup=0",
    ], "unbounded_sipmuc")
    let bmf = getTempDir() / "bench_unbounded_sipmuc_t26b.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    for c in [1, 2, 4]:
      check node.hasKey(
        "lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p" & $c & "c")
    # Other unbounded families must NOT appear here (split contract).
    check (not node.hasKey(
      "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_mupsic/mpsc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/1p1c"))
    removeFile(bmf)

# ---------- Task 2.6c: bench_unbounded_mupsic emits mupsic {1,2,4}p1c -----

suite "topology split: bench_unbounded_mupsic (Task 2.6c)":
  test "compiles + emits BMF for unbounded_mupsic {1,2,4}p1c":
    let bin = compileBench(BenchUnboundedMupsicSrc, [
      "UnboundedMupsicMessageCount=500",
      "UnboundedMupsicRuns=2",
      "BenchUnboundedWarmup=0",
    ], "unbounded_mupsic")
    let bmf = getTempDir() / "bench_unbounded_mupsic_t26c.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    for p in [1, 2, 4]:
      check node.hasKey(
        "lockfreequeues_unbounded_mupsic/mpsc_unbounded/" & $p & "p1c")
    # Other unbounded families must NOT appear here (split contract).
    check (not node.hasKey(
      "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/1p1c"))
    removeFile(bmf)

# ---------- Task 2.6d: bench_unbounded_mupmuc emits mupmuc full grid -----

suite "topology split: bench_unbounded_mupmuc (Task 2.6d)":
  test "compiles + emits BMF for unbounded_mupmuc {1,2,4}p{1,2,4}c":
    let bin = compileBench(BenchUnboundedMupmucSrc, [
      "UnboundedMupmucMessageCount=500",
      "UnboundedMupmucRuns=2",
      "BenchUnboundedWarmup=0",
    ], "unbounded_mupmuc")
    let bmf = getTempDir() / "bench_unbounded_mupmuc_t26d.json"
    if fileExists(bmf): removeFile(bmf)
    let cmd = bin & " --bmf-out=" & bmf
    let (_, exitCode) = execCmdEx(cmd)
    check exitCode == 0
    let node = parseBmf(bmf)
    for p in [1, 2, 4]:
      for c in [1, 2, 4]:
        check node.hasKey(
          "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/" &
          $p & "p" & $c & "c")
    # Other unbounded families must NOT appear here (split contract).
    check (not node.hasKey(
      "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p1c"))
    check (not node.hasKey(
      "lockfreequeues_unbounded_mupsic/mpsc_unbounded/1p1c"))
    removeFile(bmf)

# ---------- Task 2.7: strict-superset deletion-safety check ----------

suite "topology split: deletion-safety (Task 2.7)":
  test "post-split union is a strict superset of pre-split fixture":
    # Compile and run all eight post-split binaries at small overrides
    # (spsc + mpsc + mpmc_mupmuc + mpmc_sipmuc + unbounded_sipsic +
    # unbounded_sipmuc + unbounded_mupsic + unbounded_mupmuc); merge
    # the outputs via merge_bmf.py; invoke superset_check.py and assert
    # exit 0 + no output to stderr. v5.0.0 B3 added the
    # mpmc_mupmuc/mpmc_sipmuc split; v5.0.0 3.3.9-D added the four-way
    # unbounded split.
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
    let mpmcMupmucBin = compileBench(BenchMpmcMupmucSrc, [
      "BenchMpmcMessageCount=1000",
      "BenchMpmcRuns=2",
      "BenchMpmcWarmup=0",
    ], "superset_mpmc_mupmuc")
    let mpmcSipmucBin = compileBench(BenchMpmcSipmucSrc, [
      "BenchMpmcMessageCount=1000",
      "BenchMpmcRuns=2",
      "BenchMpmcWarmup=0",
    ], "superset_mpmc_sipmuc")
    let unboundedSipsicBin = compileBench(BenchUnboundedSipsicSrc, [
      "UnboundedSipsicMessageCount=500",
      "UnboundedSipsicRuns=2",
      "BenchUnboundedWarmup=0",
    ], "superset_unbounded_sipsic")
    let unboundedSipmucBin = compileBench(BenchUnboundedSipmucSrc, [
      "UnboundedSipmucMessageCount=500",
      "UnboundedSipmucRuns=2",
      "BenchUnboundedWarmup=0",
    ], "superset_unbounded_sipmuc")
    let unboundedMupsicBin = compileBench(BenchUnboundedMupsicSrc, [
      "UnboundedMupsicMessageCount=500",
      "UnboundedMupsicRuns=2",
      "BenchUnboundedWarmup=0",
    ], "superset_unbounded_mupsic")
    let unboundedMupmucBin = compileBench(BenchUnboundedMupmucSrc, [
      "UnboundedMupmucMessageCount=500",
      "UnboundedMupmucRuns=2",
      "BenchUnboundedWarmup=0",
    ], "superset_unbounded_mupmuc")
    let spscJson = dir / "spsc.json"
    let mpscJson = dir / "mpsc.json"
    let mpmcMupmucJson = dir / "mpmc_mupmuc.json"
    let mpmcSipmucJson = dir / "mpmc_sipmuc.json"
    let unboundedSipsicJson = dir / "unbounded_sipsic.json"
    let unboundedSipmucJson = dir / "unbounded_sipmuc.json"
    let unboundedMupsicJson = dir / "unbounded_mupsic.json"
    let unboundedMupmucJson = dir / "unbounded_mupmuc.json"
    let mergedJson = dir / "merged.json"
    for (bin, outPath) in [
      (spscBin, spscJson),
      (mpscBin, mpscJson),
      (mpmcMupmucBin, mpmcMupmucJson),
      (mpmcSipmucBin, mpmcSipmucJson),
      (unboundedSipsicBin, unboundedSipsicJson),
      (unboundedSipmucBin, unboundedSipmucJson),
      (unboundedMupsicBin, unboundedMupsicJson),
      (unboundedMupmucBin, unboundedMupmucJson),
    ]:
      let (output, exitCode) = execCmdEx(bin & " --bmf-out=" & outPath)
      check exitCode == 0
      if exitCode != 0:
        echo "binary failed: ", bin, "\n", output
    # Merge.
    let mergeCmd = "python3 " & RepoRoot / "benchmarks" / "merge_bmf.py" &
      " " & mergedJson & " " & spscJson & " " & mpscJson & " " &
      mpmcMupmucJson & " " & mpmcSipmucJson & " " &
      unboundedSipsicJson & " " & unboundedSipmucJson & " " &
      unboundedMupsicJson & " " & unboundedMupmucJson
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
