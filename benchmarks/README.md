# Benchmark Suite

Throughput and latency benchmarks for lockfreequeues, plus a cloud-based
regression gate via [Bencher.dev](https://bencher.dev).

## Structure

- `nim/` - Nim benchmarks (lockfreequeues, Loony, Nim channels)
- `results/` - JSON output from local benchmark runs
- `runner.py` - Orchestrates local benchmark execution
- `bmf_adapter.py` - Converts `bench_throughput` stdout to Bencher Metric Format
- `test_bmf_adapter.py` - Unit tests for the BMF adapter

## Quick Start (local)

```bash
# Run all Nim throughput benchmarks (1M messages × 33 runs - takes a while).
nim c -r -d:release -d:danger --threads:on benchmarks/nim/bench_throughput.nim

# Same, but the CI wall-clock budget (100k × 5).
nim c -r -d:release -d:danger --threads:on \
  -d:MessageCount=100000 -d:DefaultRuns=5 -d:WarmupRuns=2 \
  -d:UnboundedMupsicRuns=5 \
  benchmarks/nim/bench_throughput.nim

# Convert the captured stdout to BMF JSON for upload / inspection.
./.tmp/bench_throughput > bench_output.txt
python3 benchmarks/bmf_adapter.py bench_output.txt bench_results.json
```

## Metrics

- **Throughput**: `ops/ms` with N producer / N consumer threads
  (mean, optional min/max for unbounded variants).
- **Latency**: RTT nanoseconds with percentiles (p50, p95, p99, p999).

## Cloud benchmarking (Bencher.dev)

`.github/workflows/bench.yml` runs `bench_throughput` on `ubuntu-latest`
for every PR and every push to `main`/`devel`. The workflow:

1. Compiles `bench_throughput` with the CI run shape
   (`-d:MessageCount=100000 -d:DefaultRuns=5 -d:WarmupRuns=2
   -d:UnboundedMupsicRuns=5`).
2. Captures stdout to `bench_output.txt`.
3. Runs `bmf_adapter.py` to emit `bench_results.json` in
   [Bencher Metric Format](https://bencher.dev/docs/reference/bencher-metric-format/).
4. Uploads the JSON to the `lockfreequeues` Bencher project via the
   `bencherdev/bencher@main` action.

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
PR / push events still produce the `bench_results.json` artifact in the
job log so local debugging is possible without the upload.

### BMF schema emitted

```json
{
  "<variant>/<P>p<C>c": {
    "throughput": {
      "value": <mean ops/ms>,
      "lower_value": <min ops/ms, optional>,
      "upper_value": <max ops/ms, optional>
    }
  }
}
```

`<variant>` is one of `sipsic`, `mupmuc`, `unbounded_mupsic`, `channels`.
`lower_value` / `upper_value` are populated only for blocks that print a
`min: ... max: ...` line (currently only the `unbounded_mupsic` group).
Non-finite samples (`inf`, `nan`) are dropped with a stderr warning so
spurious cold-cache outliers do not poison the upload.

## Running adapter tests

```bash
python3 benchmarks/test_bmf_adapter.py -v
```

The tests use only the Python standard library (`unittest`) and run in
< 0.1s. They cover full and partial bench output, unknown variants, and
the CLI's exit codes.
