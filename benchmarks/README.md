# Benchmark Suite

Throughput and latency benchmarks for lockfreequeues, plus a cloud-based
regression gate via [Bencher.dev](https://bencher.dev).

## Structure

- `nim/` - Nim benchmarks (lockfreequeues, Loony, Nim channels)
- `nim/bench_common.nim` - Shared bench harness (BMF emission, stats,
  Histogram with top-K + reservoir percentiles, throughput / latency
  runners). One module, consumed by every per-topology bench binary.
- `nim/bench_throughput.nim` - Throughput driver. Emits Bencher Metric
  Format JSON natively via `--bmf-out=<path>`.
- `nim/adapters/` - One file per upstream queue library
  (`<library_slug>_adapter.nim`). Adapters expose a `push(value)
  -> PushResult` / `pop() -> PopResult[T]` shape consumed by the
  shared harness.
- `merge_bmf.py` - Stateless union of per-binary BMF JSON fragments
  into a single `merged.json` for `bencher run`. Exits 1 on
  `(slug, measure)` collisions naming the colliding inputs.
- `results/` - JSON output from local benchmark runs
- `runner.py` - Orchestrates local benchmark execution

## Quick Start (local)

```bash
# Run all Nim throughput benchmarks (1M messages x 33 runs - takes a while).
nim c -r -d:release -d:danger --threads:on benchmarks/nim/bench_throughput.nim

# Same, but the CI wall-clock budget (100k x 5).
nim c -r -d:release -d:danger --threads:on \
  -d:MessageCount=100000 -d:DefaultRuns=5 -d:WarmupRuns=2 \
  -d:UnboundedMupsicRuns=5 \
  benchmarks/nim/bench_throughput.nim

# Emit BMF JSON natively (no Python parser; see merge step below).
./.tmp/bench_throughput --bmf-out=throughput.json
python3 benchmarks/merge_bmf.py merged.json throughput.json
```

## Metrics

- **Throughput**: `ops/ms` with N producer / N consumer threads
  (mean, optional min/max for unbounded variants).
- **Latency**: RTT nanoseconds with percentiles (p50, p95, p99, p999).

## Cloud benchmarking (Bencher.dev)

`.github/workflows/bench.yml` runs `bench_throughput` on `ubuntu-latest`
for every PR and every push to `main`/`devel`. The workflow:

1. Compiles `bench_throughput` with the CI run shape
   (`-d:MessageCount=1000000 -d:DefaultRuns=5 -d:WarmupRuns=2
   -d:UnboundedMupsicRuns=3 -d:UnboundedMupsicMessageCount=500000`).
2. Runs `bench_throughput --bmf-out=throughput.json`, which writes
   Bencher Metric Format JSON natively.
3. Runs `python3 benchmarks/merge_bmf.py merged.json throughput.json`
   to produce a single `merged.json` for upload. The merge step is a
   no-op union today, but stays in place for the per-topology binary
   split landing in PR 2-4.
4. Uploads `merged.json` to the `lockfreequeues` Bencher project via
   the `bencherdev/bencher@main` action.

On pull requests, Bencher posts a comparison comment against the base
branch using `--start-point-clone-thresholds` and `--start-point-reset`,
so threshold breaches show up inline.

The workflow also runs on `workflow_dispatch` for ad-hoc baseline pinning.

### One-time setup (maintainer)

The cloud workflow requires:

1. A Bencher.dev project named `lockfreequeues`
   (create at https://bencher.dev with that exact slug).
2. A repository secret `BENCHER_API_TOKEN` containing a Bencher API token
   with write access to the project.

Until those exist the `bench` workflow will fail on the upload step;
PR / push events still produce the `merged.json` artifact in the
job log so local debugging is possible without the upload.

### BMF schema emitted

```json
{
  "<library_slug>/<topology>/<P>p<C>c": {
    "throughput_ops_ms": {
      "value": <mean ops/ms>,
      "lower_value": <mean - stddev>,
      "upper_value": <mean + stddev>
    }
  }
}
```

Slugs are alpha-sorted at the top level and measures are alpha-sorted
within each slug. `lower_value` / `upper_value` are omitted when the
emitter receives `NaN` sentinels for the bounds. Current slug set
emitted by `bench_throughput`:

- `lockfreequeues_sipsic/spsc/1p1c`
- `lockfreequeues_mupmuc/mpmc/{1,2,4,8}p{1,2,4,8}c`
- `lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c`
- `nim_channels/mpmc/{1,2,4}p{1,2,4}c`

## Running merge_bmf tests

```bash
python3 -m unittest benchmarks.tests.test_merge_bmf -v
```

The tests use only the Python standard library (`unittest`) and run in
< 0.1s. They cover slug regex enforcement, measure regex enforcement,
collision detection (with both colliding files named in stderr), and
alpha-sorted output.
