## Tests for benchmarks/render_readme.nim — README block renderer.
##
## Task 0.13 (PR 0 bench-rollup): render_readme.nim now consumes the
## new BMF shape (`{slug: {measure: MeasureValue}}`) emitted by
## `bench_throughput --bmf-out` (Task 0.10) + `merge_bmf.py` (Task 0.7).
## The legacy `{results: [{...}], metadata: {...}}` shape was the
## bench_main aggregator output; bench_main is deleted in Task 0.12.
##
## Test strategy: write a fixture BMF JSON to a temp file, invoke
## `loadRows` (the file-parsing entry point) directly via include of
## the renderer module, and assert that the resulting `Row` sequence
## contains the expected impl/thread/throughput triples.
##
## The include needs `-d:renderReadmeNoMain` to suppress the renderer's
## CLI block (which mutates the project README). The define is wired
## via `tests/config.nims` for this particular test binary; without it
## the test would silently rewrite README.md from inside `unittest2`.

# Note: render_readme.nim re-imports `json`, `os`, `strutils`, `algorithm`
# below via `include`, so we deliberately avoid re-importing them here
# (Nim emits "duplicate import" hints for the include's own imports).
# Only `unittest2` is needed at the test level.
import unittest2

# Include the renderer source so its private `loadRows`, `Row`, and
# `renderTable` symbols are reachable. Including (vs importing) is
# correct here because loadRows et al. are file-private — the binary
# is consumed via `nim r`, not as a library — so re-exporting them
# would change the public surface for no benefit. The include path
# walks from `tests/` up to the repo root and into `benchmarks/`.
{.define: renderReadmeNoMain.}
include ../benchmarks/render_readme

const FixtureBmf = """
{
  "lockfreequeues_mupmuc/mpmc/2p2c": {
    "throughput_ops_ms": {
      "value": 7411.0,
      "lower_value": 7400.0,
      "upper_value": 7422.0
    }
  },
  "lockfreequeues_sipsic/spsc/1p1c": {
    "throughput_ops_ms": {
      "value": 6280.5
    }
  },
  "nim_channels/mpmc/1p1c": {
    "throughput_ops_ms": {
      "value": 1234.5
    }
  }
}
"""

suite "render_readme Task 0.13: new BMF shape":
  test "loadRows decomposes BMF slugs into impl + thread_config rows":
    let path = getTempDir() / "render_readme_t013.json"
    writeFile(path, FixtureBmf)
    let (rows, meta) = loadRows(path)
    removeFile(path)
    # Sorted alpha by impl, then by thread_config (ascending). The
    # current sort lambda in render_readme.nim handles that.
    check rows.len == 3
    # rows[0]: lockfreequeues_mupmuc/mpmc/2p2c
    check rows[0].impl == "lockfreequeues_mupmuc"
    check rows[0].threads == "2P/2C"
    check rows[0].throughput == 7411.0
    # rows[1]: lockfreequeues_sipsic/spsc/1p1c
    check rows[1].impl == "lockfreequeues_sipsic"
    check rows[1].threads == "1P/1C"
    check rows[1].throughput == 6280.5
    # rows[2]: nim_channels/mpmc/1p1c
    check rows[2].impl == "nim_channels"
    check rows[2].threads == "1P/1C"
    check rows[2].throughput == 1234.5
    # Latency was not emitted in PR 0; should be marked absent.
    check rows[0].hasLatency == false
    check rows[1].hasLatency == false
    check rows[2].hasLatency == false
    # New BMF shape carries no `metadata` block; renderer must accept
    # `meta == nil` and still render a header-less table without crashing.
    check meta == nil

  test "rendered table contains expected rows and no latency column data":
    let path = getTempDir() / "render_readme_t013_render.json"
    writeFile(path, FixtureBmf)
    let body = renderBlock(path)
    removeFile(path)
    # Header is unchanged.
    check body.contains("| implementation | threads | throughput (ops/ms) | p50 latency (ns) |")
    # Each impl appears in a row.
    check body.contains("`lockfreequeues_mupmuc`")
    check body.contains("`lockfreequeues_sipsic`")
    check body.contains("`nim_channels`")
    # Throughput values render with 1 decimal.
    check body.contains("7411.0")
    check body.contains("6280.5")
    check body.contains("1234.5")
    # Latency column is em-dash for every row (no p50 measure).
    let dashCount = body.count("| — |")
    check dashCount == 3

  test "missing JSON file produces placeholder, no crash":
    let path = getTempDir() / "render_readme_t013_missing.json"
    if fileExists(path): removeFile(path)
    let body = renderBlock(path)
    check body.contains("_no benchmark results checked in_")

  test "empty BMF document produces placeholder":
    let path = getTempDir() / "render_readme_t013_empty.json"
    writeFile(path, "{}")
    let body = renderBlock(path)
    removeFile(path)
    check body.contains("_no benchmark results checked in_")
