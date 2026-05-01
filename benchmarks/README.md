# Benchmark Suite

Throughput and latency benchmarks for lockfreequeues, plus a cloud-based
regression gate via [Bencher.dev](https://bencher.dev).

## Structure

- `nim/` - Nim benchmarks (lockfreequeues + Nim channels).
- `nim/bench_common.nim` - Shared bench harness (BMF emission, stats,
  Histogram with top-K + reservoir percentiles, throughput / latency
  runners). One module, consumed by every per-topology bench binary.
- `nim/bench_spsc.nim` - Bounded SPSC throughput driver (Sipsic 1p1c).
- `nim/bench_mpsc.nim` - Bounded MPSC throughput driver
  (Mupsic {1,2,4}p1c).
- `nim/bench_mpmc.nim` - Bounded MPMC throughput driver
  (Mupmuc {1,2,4}p{1,2,4}c plus 8p8c oversubscription, Sipmuc 1p{1,2,4}c,
  Nim channels {1,2,4}p{1,2,4}c).
- `nim/bench_unbounded.nim` - Unbounded throughput driver across all
  four lockfreequeues unbounded variants.
- `nim/bench_latency.nim` - Latency (ping-pong RTT) driver across the
  four bounded lockfreequeues variants.
- `nim/adapters/` - One file per upstream queue library
  (`<library_slug>_adapter.nim`). Adapters expose a `push(value)
  -> PushResult` / `pop() -> PopResult[T]` shape consumed by the
  shared harness; multi-thread topologies bypass the generic adapter
  and call queue.getProducer(idx) / queue.getConsumer(idx) directly.
- `nim/smoke/` - Compile-and-run sanity binaries for FFI adapters
  (`smoke_boost.nim`, `smoke_crossbeam.nim`). Each is a 32-item push/pop
  round-trip used by CI to fail fast when a system library or cdylib
  is unavailable, before paying the cost of a full bench compile.
- `rust/bench-ffi-crossbeam/` - C-ABI cdylib wrapping
  `crossbeam_queue::ArrayQueue<u64>` and `crossbeam_queue::SegQueue<u64>`.
  Built with `cargo build --release`; consumed by the Nim Crossbeam
  adapters via `importc`.
- `merge_bmf.py` - Stateless union of per-binary BMF JSON fragments
  into a single `merged.json` for `bencher run`. Exits 1 on
  `(slug, measure)` collisions naming the colliding inputs.
- `scripts/superset_check.py` - Slug-set deletion-safety guard. Exits
  1 with the missing slug list on stderr if a post-split BMF drops
  any slug present in the pre-split fixture
  (`tests/fixtures/pre-split-slugs.json`).
- `results/` - JSON output from local benchmark runs.
- `runner.py` - Orchestrates local benchmark execution. Builds and
  runs all five binaries, then merges their fragments via
  `merge_bmf.py`.

## Quick Start (local)

```bash
# Run every topology binary at default run shape (1M messages * 33
# runs for bounded throughput; 500K * 3 for unbounded; 100K * 33 for
# latency). Takes a while.
nimble benchmarks

# CI-tighter shape: pick one binary and override its per-binary
# intdefines. Each binary owns its own knobs (design doc 2.5).
nim c -r -d:release -d:danger --threads:on \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=5 -d:BenchMpmcWarmup=2 \
  benchmarks/nim/bench_mpmc.nim

# Emit BMF JSON natively (no Python parser; merge to combine).
./.tmp/bench_spsc       --bmf-out=spsc.json
./.tmp/bench_mpsc       --bmf-out=mpsc.json
./.tmp/bench_mpmc       --bmf-out=mpmc.json
./.tmp/bench_unbounded  --bmf-out=unbounded.json
./.tmp/bench_latency    --bmf-out=latency.json
python3 benchmarks/merge_bmf.py merged.json \
  spsc.json mpsc.json mpmc.json unbounded.json latency.json
```

## Metrics

- **Throughput**: `ops/ms` with N producer / N consumer threads
  (mean, lower=mean-stddev, upper=mean+stddev).
- **Latency**: RTT nanoseconds with percentiles (p50, p95, p99).

## Cloud benchmarking (Bencher.dev)

`.github/workflows/bench.yml` runs the five topology-split binaries on
`ubuntu-latest` for every PR and every push to `main`/`devel` via a
GitHub Actions matrix (one matrix entry per binary, each with its own
`timeout-minutes: 12` budget). The workflow:

1. Compiles each binary with its CI-tuned per-binary intdefines
   (e.g. `-d:BenchSpscMessageCount=1000000 -d:BenchSpscRuns=5
   -d:BenchSpscWarmup=2` for `bench_spsc`).
2. Runs the binary with `--bmf-out=<binary>.json`, which writes
   Bencher Metric Format JSON natively.
3. Uploads each per-binary JSON as a GitHub Actions artifact.
4. The dependent `bench-upload` job downloads every artifact, unions
   them via `merge_bmf.py merged.json $(ls bmf-inputs/*.json)`, then
   runs `superset_check.py tests/fixtures/pre-split-slugs.json
   merged.json` to enforce deletion-safety. A single `bencher run`
   uploads `merged.json` to the `lockfreequeues` Bencher project.

On pull requests, Bencher posts a comparison comment against the base
branch using `--start-point-clone-thresholds` and `--start-point-reset`,
so threshold breaches show up inline.

The workflow also runs on `workflow_dispatch` for ad-hoc baseline
pinning.

### One-time setup (maintainer)

The cloud workflow requires:

1. A Bencher.dev project named `lockfreequeues`
   (create at https://bencher.dev with that exact slug).
2. A repository secret `BENCHER_API_TOKEN` containing a Bencher API
   token with write access to the project.

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
    },
    "latency_p50_ns": {"value": <ns>},
    "latency_p95_ns": {"value": <ns>},
    "latency_p99_ns": {"value": <ns>}
  }
}
```

Slugs are alpha-sorted at the top level and measures are alpha-sorted
within each slug. `lower_value` / `upper_value` are omitted when the
emitter receives `NaN` sentinels for the bounds. After `merge_bmf.py`
unions the five binary fragments, a single slug can carry both
`throughput_ops_ms` (from the matching topology binary) AND
`latency_p50_ns` / `latency_p95_ns` / `latency_p99_ns` (from
`bench_latency`) when the slug shape matches `1p1c` on a bounded
variant.

Current slug set emitted across the five binaries:

- `bench_spsc`: `lockfreequeues_sipsic/spsc/1p1c`.
- `bench_mpsc`: `lockfreequeues_mupsic/mpsc/{1,2,4}p1c`.
- `bench_mpmc`: `lockfreequeues_mupmuc/mpmc/{1,2,4}p{1,2,4}c` plus
  `lockfreequeues_mupmuc/mpmc/8p8c`,
  `lockfreequeues_sipmuc/mpmc/1p{1,2,4}c`,
  `nim_channels/mpmc/{1,2,4}p{1,2,4}c`.
- `bench_unbounded`:
  `lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c`,
  `lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p{1,2,4}c`,
  `lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c`,
  `lockfreequeues_unbounded_mupmuc/mpmc_unbounded/{1,2,4}p{1,2,4}c`.
- `bench_latency`:
  `lockfreequeues_{sipsic,sipmuc,mupsic,mupmuc}/{spsc,mpmc,mpsc,mpmc}/1p1c`.

## Comparison MVP — third-party adapters

PR 3 (Track 3) adds five external-library adapters so each topology has
≥ 3 distinct libraries plotted on the same Bencher dashboard. All
adapters are gated behind `-d:adapter_<library_slug>_available`; absent
gates produce no symbol references and the production builds are
unchanged.

| Library | Variant | Topology | Compile gate | Install (Linux CI) |
|---------|---------|----------|--------------|--------------------|
| Loony | `LoonyQueue` | `mpmc_unbounded` | `-d:adapter_loony_available` | `nimble install loony` |
| Boost.LockFree | `boost::lockfree::queue` | `mpmc` (bounded) | `-d:adapter_boost_lockfree_queue_available` | `apt install libboost-dev` (requires `nim cpp`) |
| Boost.LockFree | `boost::lockfree::spsc_queue` | `spsc` (bounded) | `-d:adapter_boost_lockfree_spsc_available` | same as above |
| Crossbeam | `crossbeam_queue::ArrayQueue` | `mpmc` (bounded) | `-d:adapter_crossbeam_array_queue_available` | `cargo build --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml` |
| Crossbeam | `crossbeam_queue::SegQueue` | `mpmc_unbounded` | `-d:adapter_crossbeam_seg_queue_available` | same as above |

Library upstreams: [Loony](https://github.com/shayanhabibi/loony) (MIT),
[Boost.LockFree](https://www.boost.org/libs/lockfree/) (BSL-1.0),
[Crossbeam](https://github.com/crossbeam-rs/crossbeam) (Apache-2.0 OR MIT).
Per-library obligations are tracked in
[`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md).

### CI integration

- **`bench.yml`** runs Loony + Boost.LockFree on every PR using the
  soft-skip pattern (design 2.6): each library has install -> smoke ->
  set-flag stages with `continue-on-error: true`; if install or smoke
  fails the binary compiles without that adapter and the workflow emits
  a `::warning title=Adapter skipped::...` annotation. The
  `workflow_dispatch` event also accepts `force_skip_boost` /
  `force_skip_loony` boolean inputs to exercise the skip path manually.
- **`bench-comparison.yml`** runs Crossbeam (the only adapter with a
  Rust toolchain dependency) on a nightly cron + `workflow_dispatch` +
  targeted path pushes to `devel`. It produces a separate Bencher
  Report dedicated to crossbeam slugs.

### Running comparison adapters locally

```bash
# Loony (Nim only):
nimble install loony
nim c -r -d:release -d:danger --threads:on \
  -d:adapter_loony_available \
  -d:UnboundedMupmucMessageCount=100000 -d:UnboundedMupmucRuns=3 \
  benchmarks/nim/bench_unbounded.nim loony

# Boost (C++ headers; macOS: brew install boost; Ubuntu: apt install libboost-dev):
nim cpp -r -d:release -d:danger --threads:on \
  -d:adapter_boost_lockfree_queue_available \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=3 \
  benchmarks/nim/bench_mpmc.nim boost_lockfree_queue

# Crossbeam (Rust cdylib):
cargo build --release \
  --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml
nim c -r -d:release -d:danger --threads:on \
  -d:adapter_crossbeam_array_queue_available \
  --passL:"-Wl,-rpath,$(pwd)/benchmarks/rust/bench-ffi-crossbeam/target/release" \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=3 \
  benchmarks/nim/bench_mpmc.nim crossbeam_array_queue
```

## Running merge_bmf and superset_check tests

```bash
python3 -m unittest benchmarks.tests.test_merge_bmf -v
python3 -m unittest benchmarks.tests.test_superset_check -v
```

The tests use only the Python standard library (`unittest`) and run in
under a second. They cover slug regex enforcement, measure regex
enforcement, collision detection (with both colliding files named in
stderr), alpha-sorted output, 5-input union (one fragment per
topology binary), and the deletion-safety contract enforced by
`superset_check.py`.
