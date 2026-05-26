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
- `nim/bench_mpmc_mupmuc.nim` - Bounded MPMC throughput driver, Mupmuc
  family (Mupmuc {1,2,4}p{1,2,4}c plus 8p8c oversubscription, Queue
  ccMulti×ccMulti parity at the same shapes, Nim channels
  {1,2,4}p{1,2,4}c, plus the MVP comparison adapters whose slug shape
  matches the mupmuc grid).
- `nim/bench_mpmc_sipmuc.nim` - Bounded MPMC throughput driver, Sipmuc
  family (Sipmuc 1p{1,2,4}c, Queue ccSingle×ccMulti parity at the same
  shapes). v5.0.0 B3 split the original `bench_mpmc.nim` into these
  two per-family binaries to eliminate cross-family iCache contention
  that was producing a spurious -39.6% throughput artifact on
  `sipmuc/mpmc/1p1c`; see the file headers for the diagnostic.
- `nim/bench_unbounded_sipsic.nim` - Unbounded throughput driver,
  UnboundedSipsic family (1p1c). v5.0.0 3.3.9-D split the original
  `bench_unbounded.nim` into four per-family binaries (this file plus
  the three below) to eliminate cross-family iCache contention that
  was producing -17% to -34% throughput regressions on
  unbounded_mupmuc/2p2c, unbounded_mupsic/2p1c, and
  unbounded_mupsic/4p1c; see the file headers for the diagnostic.
- `nim/bench_unbounded_sipmuc.nim` - Unbounded throughput driver,
  UnboundedSipmuc family (1p{1,2,4}c).
- `nim/bench_unbounded_mupsic.nim` - Unbounded throughput driver,
  UnboundedMupsic family ({1,2,4}p1c).
- `nim/bench_unbounded_mupmuc.nim` - Unbounded throughput driver,
  UnboundedMupmuc family ({1,2,4}p{1,2,4}c full grid plus the MVP
  comparison adapters whose slug shape matches the mupmuc unbounded
  grid: Loony, Crossbeam SegQueue, MoodyCamel).
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
  runs all nine topology-split binaries (post 3.3.9-D), then merges
  their fragments via `merge_bmf.py`.

## Quick Start (local)

```bash
# Run every topology binary at default run shape (1M messages * 33
# runs for bounded throughput; 500K * 3 for unbounded; 100K * 33 for
# latency). Takes a while.
nimble benchmarks

# CI-tighter shape: pick one binary and override its per-binary
# intdefines. Each binary owns its own knobs (design doc 2.5). The
# two mpmc binaries share the BenchMpmc* knobs.
nim c -r -d:release -d:danger --threads:on \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=5 -d:BenchMpmcWarmup=2 \
  benchmarks/nim/bench_mpmc_mupmuc.nim

# Emit BMF JSON natively (no Python parser; merge to combine).
./.tmp/bench_spsc                --bmf-out=spsc.json
./.tmp/bench_mpsc                --bmf-out=mpsc.json
./.tmp/bench_mpmc_mupmuc         --bmf-out=mpmc_mupmuc.json
./.tmp/bench_mpmc_sipmuc         --bmf-out=mpmc_sipmuc.json
./.tmp/bench_unbounded_sipsic    --bmf-out=unbounded_sipsic.json
./.tmp/bench_unbounded_sipmuc    --bmf-out=unbounded_sipmuc.json
./.tmp/bench_unbounded_mupsic    --bmf-out=unbounded_mupsic.json
./.tmp/bench_unbounded_mupmuc    --bmf-out=unbounded_mupmuc.json
./.tmp/bench_latency             --bmf-out=latency.json
python3 benchmarks/merge_bmf.py merged.json \
  spsc.json mpsc.json mpmc_mupmuc.json mpmc_sipmuc.json \
  unbounded_sipsic.json unbounded_sipmuc.json \
  unbounded_mupsic.json unbounded_mupmuc.json \
  latency.json
```

## Metrics

- **Throughput**: `ops/ms` with N producer / N consumer threads
  (mean, lower=mean-stddev, upper=mean+stddev).
- **Latency**: RTT nanoseconds with percentiles (p50, p95, p99).

## Cloud benchmarking (Bencher.dev)

`.github/workflows/bench.yml` runs the topology-split binaries on
`ubuntu-latest` for every PR and every push to `main`/`devel` via a
GitHub Actions matrix (one matrix entry per binary, each with its own
`timeout-minutes: 18` budget). v5.0.0 B3 split the `bench_mpmc` slot
into `bench_mpmc_mupmuc` + `bench_mpmc_sipmuc`; v5.0.0 3.3.9-D fanned
the `bench_unbounded` slot into four per-family binaries
(`bench_unbounded_{sipsic,sipmuc,mupsic,mupmuc}`) so each family runs
in parallel as an independent matrix entry. The workflow:

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

Current slug set emitted across the topology-split binaries:

- `bench_spsc`: `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_queue_bounded_sipsic/spsc/1p1c`.
- `bench_mpsc`: `lockfreequeues_mupsic/mpsc/{1,2,4}p1c`,
  `lockfreequeues_queue_bounded_mupsic/mpsc/{1,2,4}p1c`.
- `bench_mpmc_mupmuc`:
  `lockfreequeues_mupmuc/mpmc/{1,2,4}p{1,2,4}c` plus
  `lockfreequeues_mupmuc/mpmc/8p8c`,
  `lockfreequeues_queue_bounded_mupmuc/mpmc/{1,2,4}p{1,2,4}c` plus
  `lockfreequeues_queue_bounded_mupmuc/mpmc/8p8c`,
  `nim_channels/mpmc/{1,2,4}p{1,2,4}c`.
- `bench_mpmc_sipmuc`:
  `lockfreequeues_sipmuc/mpmc/1p{1,2,4}c`,
  `lockfreequeues_queue_bounded_sipmuc/mpmc/1p{1,2,4}c`.
- `bench_unbounded_sipsic`:
  `lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c`.
- `bench_unbounded_sipmuc`:
  `lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p{1,2,4}c`.
- `bench_unbounded_mupsic`:
  `lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c`.
- `bench_unbounded_mupmuc`:
  `lockfreequeues_unbounded_mupmuc/mpmc_unbounded/{1,2,4}p{1,2,4}c`.
- `bench_latency`:
  `lockfreequeues_{sipsic,sipmuc,mupsic,mupmuc}/{spsc,mpmc,mpsc,mpmc}/1p1c`.

## Comparison libraries — third-party adapters

PR 3 (Track 3) introduced the comparison MVP with five
external-library adapters; PR 4 (Track 4) extended the set to seven
upstream libraries / nine adapter variants. v5.0.0 lands another four
vendored C/C++ targets (`atomic_queue`, `liblfds`, `rigtorp_mpmc`,
`rigtorp_spsc`) and two additional Rust crates (`flume`, `kanal`)
that ride alongside `crossbeam-queue` in the existing
`bench-ffi-crossbeam` cdylib — bringing the comparison set to twelve
upstream libraries / eighteen adapter variants so each topology has
≥ 3 distinct libraries plotted on the same Bencher dashboard. All
adapters are gated behind `-d:adapter_<library_slug>_available`;
absent gates produce no symbol references and the production builds
are unchanged.

| Library | Variant | Topology | Compile gate | Install (Linux CI) |
|---------|---------|----------|--------------|--------------------|
| Loony | `LoonyQueue` | `mpmc_unbounded` | `-d:adapter_loony_available` | `nimble install loony` |
| Boost.LockFree | `boost::lockfree::queue` | `mpmc` (bounded) | `-d:adapter_boost_lockfree_queue_available` | `apt install libboost-dev` (requires `nim cpp`) |
| Boost.LockFree | `boost::lockfree::spsc_queue` | `spsc` (bounded) | `-d:adapter_boost_lockfree_spsc_available` | same as above |
| Crossbeam | `crossbeam_queue::ArrayQueue` | `mpmc` (bounded) | `-d:adapter_crossbeam_array_queue_available` | `cargo build --release --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml` |
| Crossbeam | `crossbeam_queue::SegQueue` | `mpmc_unbounded` | `-d:adapter_crossbeam_seg_queue_available` | same as above |
| MoodyCamel | `concurrentqueue::ConcurrentQueue` | `mpmc_unbounded` | `-d:adapter_moodycamel_available` | vendored at `benchmarks/vendor/concurrentqueue/` (requires `nim cpp`) |
| nimble `threading` | `threading.Chan` | `mpmc` (bounded) | `-d:adapter_threading_channels_available` | `nimble install threading` |
| Nim `system.Channel` | `system/channels.Channel` | `mpsc` (bounded, blocking-on-full producer\*) | `-d:adapter_nim_channel_available` | none (Nim stdlib) |
| atomic_queue (max0x7ba) | `atomic_queue::AtomicQueueB` | `spsc` + `mpmc` (bounded) | `-d:adapter_atomic_queue_available` | vendored at `benchmarks/vendor/atomic_queue/` (requires `nim cpp`) |
| liblfds | `lfds711_queue_bss` / `_bmm` | `spsc` + `mpmc` (bounded) | `-d:adapter_liblfds_available` | vendored at `benchmarks/vendor/liblfds/` (C wrapper) |
| rigtorp::MPMCQueue | `rigtorp::mpmc::Queue` | `mpmc` (bounded) | `-d:adapter_rigtorp_mpmc_available` | vendored at `benchmarks/vendor/rigtorp_mpmc/` (requires `nim cpp`) |
| rigtorp::SPSCQueue | `rigtorp::SPSCQueue` | `spsc` (bounded) | `-d:adapter_rigtorp_spsc_available` | vendored at `benchmarks/vendor/rigtorp_spsc/` (requires `nim cpp`) |
| flume | `flume::Sender/Receiver` | `mpmc` (bounded) + `mpmc_unbounded` | `-d:adapter_flume_available` | same as Crossbeam (rides the `bench-ffi-crossbeam` cdylib) |
| kanal | `kanal::Sender/Receiver` | `spsc` + `mpmc` (bounded) + `mpmc_unbounded` | `-d:adapter_kanal_available` | same as Crossbeam (rides the `bench-ffi-crossbeam` cdylib) |

\* The `system.Channel` adapter blocks the producer when the channel
is full instead of returning back-pressure to the harness loop, so its
recorded throughput captures kernel wakeup latency. This makes the
`nim_channel/*` slugs only loosely comparable to the lock-free
adapters; the chart legend marks the slug accordingly.

Library upstreams: [Loony](https://github.com/shayanhabibi/loony)
(MIT),
[Boost.LockFree](https://www.boost.org/libs/lockfree/)
(BSL-1.0),
[Crossbeam](https://github.com/crossbeam-rs/crossbeam)
(Apache-2.0 OR MIT),
[MoodyCamel concurrentqueue](https://github.com/cameron314/concurrentqueue)
(BSD-2-Clause / Boost dual),
[nimble threading](https://github.com/nim-lang/threading) (MIT),
[Nim `system.Channel`](https://nim-lang.org) (MIT, ships with the
compiler),
[atomic_queue](https://github.com/max0x7ba/atomic_queue) (MIT),
[liblfds](https://liblfds.org/) (public-domain multi-grant; consumed
under MIT),
[rigtorp::MPMCQueue](https://github.com/rigtorp/MPMCQueue) (MIT),
[rigtorp::SPSCQueue](https://github.com/rigtorp/SPSCQueue) (MIT),
[flume](https://github.com/zesterer/flume) (Apache-2.0 OR MIT),
[kanal](https://github.com/fereidani/kanal) (MIT).
Per-library obligations are tracked in
[`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md).

### CI integration

- **`bench.yml`** runs every adapter on every PR using the soft-skip
  pattern (design §2.6): each library has install → smoke → set-flag
  stages with `continue-on-error: true`; if install or smoke fails
  the binary compiles without that adapter and the workflow emits a
  `::warning title=Adapter skipped::...` annotation. The
  `workflow_dispatch` event accepts `force_skip_boost` /
  `force_skip_loony` / `force_skip_moodycamel` /
  `force_skip_threading_channels` / `force_skip_nim_channel`
  boolean inputs to exercise the skip path manually.
- **`bench-comparison.yml`** runs Crossbeam (the only adapter with a
  Rust toolchain dependency) on a nightly cron + `workflow_dispatch`
  + targeted path pushes to `devel`. It produces a separate Bencher
  Report dedicated to crossbeam slugs.

### Version capture and pinning

Every emitted bench JSON (the per-shape files under
`benchmarks/results/` and the merged `docs/assets/bench-results/latest.json`
snapshot) carries a top-level `meta` block recording the resolved
version of each comparison adapter at run time. Schema (v1):

```json
"meta": {
  "schema": 1,
  "generated_at": "<ISO-8601 UTC>",
  "host": { "os": "...", "arch": "..." },
  "lockfreequeues_version": "5.0.0",
  "nim_version": "2.2.10",
  "adapters": {
    "<slug>": {
      "version":     "<string|null>",
      "fingerprint": "<string|null>",
      "kind":        "<in-tree|compiler-builtin|vendored-version-macro|vendored-content-hash|cargo-locked|nimble-resolved|system-package>",
      "pinned_sha_per_readme": "<optional; vendored libs only>",
      "status":      "<optional; ok|absent|build-without-*|unknown>"
    }
  },
  "absent_adapters": ["<slug>", ...]
}
```

The capture is implemented in `benchmarks/nim/adapter_versions.nim`
and is read by `benchmarks/nim/bench_common.nim`'s `BMFEmitter.emit`;
`benchmarks/merge_bmf.py` preserves the `meta` block when unioning
per-binary BMF fragments; `docs/assets/bench-charts.js` skips the
`meta` key in its slug-iteration passes via `isMeasurementSlug`.

**SHA-1 fingerprint protocol.** For vendored libraries that expose no
upstream version macro (`atomic_queue`, `concurrentqueue`/`moodycamel`,
`rigtorp_mpmc`, `rigtorp_spsc`), the `fingerprint` field is a SHA-1
digest of the concatenation of every vendored header that ships with
the adapter, in sorted filename order, each preceded by a
`\n--- <filename> ---\n` separator. Format is always `"sha1:<40-hex>"`
so downstream tools can disambiguate hash kinds if we later add
SHA-256. The bytes are captured at compile time via Nim's `staticRead`,
so the fingerprint reflects exactly what was baked into the bench
binary — any change to the vendored sources changes the fingerprint
deterministically. To compare bench JSONs across builds, compare
`meta.adapters.<lib>.fingerprint`; matching SHA-1 means the vendored
bytes are identical and the throughput comparison is apples-to-apples.

Adapter version sourcing rules (no hand-typed mirrors of README files):

- **Vendored C/C++ headers without a version macro** (`atomic_queue`,
  `concurrentqueue`/`moodycamel`, `rigtorp_mpmc`, `rigtorp_spsc`):
  `kind = vendored-content-hash`. `version` is `null` (no upstream
  version exists); `fingerprint` is the SHA-1 digest described above;
  `pinned_sha_per_readme` documents the README's pinned SHA so audits
  can compare the upstream-tracked SHA against the compile-time
  fingerprint. The fingerprint IS the integrity primitive; if the
  README pin and the compile-time bytes diverge, the fingerprint moves
  and the README claim becomes inspectable.
- **Vendored C/C++ libraries with a version macro** (`liblfds`):
  `kind = vendored-version-macro`. `version` is captured at compile
  time by `importc`-ing the upstream version macro
  (`LFDS711_MISC_VERSION_STRING`) through a tiny `{.emit.}` include —
  the same technique used for Boost. The macro expands inside the
  bench binary's C compilation, so it reflects exactly what was
  compiled in.
- **Rust crates** (`crossbeam_queue`, `flume`, `kanal`):
  `kind = cargo-locked`. Captured at build time inside the Rust cdylib
  (`benchmarks/rust/bench-ffi-crossbeam/`). A `build.rs` reads the
  project's `Cargo.lock`, emits `cargo:rustc-env=BENCH_DEP_*_VERSION`
  for each crate, and three `#[no_mangle] pub extern "C"` functions
  return the strings as NUL-terminated C cstrings via `env!()`. The
  Nim side `importc`-s the getters and calls them at run time, so the
  reported version is exactly what was linked in at cdylib build time,
  not what `Cargo.toml` requested. Bench binaries built without any
  of the Rust adapter gates record
  `{"version": null, "status": "build-without-rust-cdylib"}`.
- **Nimble-resolved** (`loony`, `threading`): the bench harness
  shells out to `nimble path <pkg>` at run time and parses the
  resolved version from the package directory name. Missing package
  -> `{"version": null, "status": "absent"}`. Production-dep pinning
  (nim, unittest2, typestates, debra) is via the committed
  `nimble.lock` at the repo root; Loony and `threading` are NOT in
  the manifest because they are bench-only optional adapters, so
  their pinning is the responsibility of the CI workflow's
  `nimble install <pkg>` step. The run-time `meta.adapters.*.version`
  capture is the cross-run-comparable record.
- **Boost.LockFree** (`boost_lockfree`): captured at compile time
  via the `BOOST_LIB_VERSION` macro from `boost/version.hpp` when
  either Boost adapter gate is enabled. Boost.LockFree is consumed
  via the system package (`apt install libboost-dev` on Ubuntu CI,
  `brew install boost` on macOS development). The version is
  therefore implicit in the OS runner image at bench time. The bench
  output JSON (`meta.adapters.boost_lockfree.version`) records the
  version captured at run time. To compare bench results across
  runs, check the `meta.adapters.boost_lockfree.version` field of
  each JSON; mismatches indicate the OS image bumped Boost and the
  comparison is not apples-to-apples. Builds without any Boost
  adapter gate record
  `{"version": null, "status": "build-without-boost"}`.
- **Nim compiler builtin** (`nim_channel`): always set to the
  `NimVersion` constant from `system`, which equals the compiler
  used for the bench compile.
- **In-tree** (`lockfreequeues`): the `LockfreequeuesVersion`
  constant from `src/lockfreequeues.nim` (mirrors the `version` line
  in `lockfreequeues.nimble`; bump in lockstep on every release).

### Running comparison adapters locally

```bash
# Loony (Nim only; lives in bench_unbounded_mupmuc post 3.3.9-D split):
nimble install loony
nim c -r -d:release -d:danger --threads:on \
  -d:adapter_loony_available \
  -d:UnboundedMupmucMessageCount=100000 -d:UnboundedMupmucRuns=3 \
  benchmarks/nim/bench_unbounded_mupmuc.nim loony

# Boost (C++ headers; macOS: brew install boost; Ubuntu: apt install libboost-dev):
nim cpp -r -d:release -d:danger --threads:on \
  -d:adapter_boost_lockfree_queue_available \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=3 \
  benchmarks/nim/bench_mpmc_mupmuc.nim boost_lockfree_queue

# Crossbeam (Rust cdylib):
cargo build --release \
  --manifest-path benchmarks/rust/bench-ffi-crossbeam/Cargo.toml
nim c -r -d:release -d:danger --threads:on \
  -d:adapter_crossbeam_array_queue_available \
  --passL:"-Wl,-rpath,$(pwd)/benchmarks/rust/bench-ffi-crossbeam/target/release" \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=3 \
  benchmarks/nim/bench_mpmc_mupmuc.nim crossbeam_array_queue

# MoodyCamel (vendored single-header; nim cpp; lives in
# bench_unbounded_mupmuc post 3.3.9-D split):
nim cpp -r -d:release -d:danger --threads:on \
  -d:adapter_moodycamel_available \
  -d:UnboundedMupmucMessageCount=100000 -d:UnboundedMupmucRuns=3 \
  benchmarks/nim/bench_unbounded_mupmuc.nim moodycamel

# nimble threading.Chan:
nimble install threading
nim c -r -d:release -d:danger --threads:on \
  -d:adapter_threading_channels_available \
  -d:BenchMpmcMessageCount=100000 -d:BenchMpmcRuns=3 \
  benchmarks/nim/bench_mpmc_mupmuc.nim threading_channels

# Nim system.Channel (no install):
nim c -r -d:release -d:danger --threads:on \
  -d:adapter_nim_channel_available \
  -d:BenchMpscMessageCount=100000 -d:BenchMpscRuns=3 \
  benchmarks/nim/bench_mpsc.nim nim_channel
```

## Running merge_bmf and superset_check tests

```bash
python3 -m unittest benchmarks.tests.test_merge_bmf -v
python3 -m unittest benchmarks.tests.test_superset_check -v
python3 -m unittest benchmarks.tests.test_bench_charts_contract -v
```

The tests use only the Python standard library (`unittest`) and run in
under a second. They cover slug regex enforcement, measure regex
enforcement, collision detection (with both colliding files named in
stderr), alpha-sorted output, 5-input union (one fragment per
topology binary), the deletion-safety contract enforced by
`superset_check.py`, and the BMF-shape contract that
`docs/assets/bench-charts.js` depends on (Track 5 PR 5).

## Refreshing the example fixture

`docs/assets/bench-results/example.json` is the middle tier of the
chart's 3-tier fallback chain (live `latest.json` → `example.json`
fixture → red error banner). It exists so the public benchmarks page
renders representative data with a yellow "fixture" status banner when
the live snapshot is unavailable, instead of a broken red banner.

The fixture must come from a real successful bench run; hand-authored
"representative" numbers are forbidden (design §5.4 shape-coverage
policy). To regenerate:

1. Pick a recent successful `bench.yml` run on `devel` whose merged BMF
   covers `mpmc/{1p1c,1p2c,2p1c,2p2c,4p4c}` plus latency at `1p1c`
   bounded variants:
   `gh run list --workflow=bench.yml --branch=devel --status=success --limit 5`.
2. Download all five per-binary BMF artifacts:
   `gh run download <run-id> --pattern 'bench-*-bmf' -D /tmp/bmf/`.
3. Merge into one BMF document via this repo's merger:
   `find /tmp/bmf/ -name '*.json' -print0 | xargs -0 python3 benchmarks/merge_bmf.py merged.json`.
4. Schema-validate (per design §5.4 step 4): every key matches
   `^[a-z][a-z0-9_]*(?:/[a-z][a-z0-9_]*)+/\d+p\d+c$` and every measure
   value carries only `value` / `lower_value` / `upper_value`.
5. Copy the merged result to
   `docs/assets/bench-results/example.json` and commit with a message
   that records the source workflow run id, head sha, and run date.

Bench-comparison adapters (Crossbeam, Loony, Boost, MoodyCamel,
threading.Chan, Nim system.Channel) only run on
`bench-comparison.yml` (nightly cron); if their slugs are absent from
the chosen `bench.yml` run, the fixture will not include them and the
chart will render only the in-house lockfreequeues + nim_channels
slugs. That is acceptable for the fallback rendering — the live
`latest.json` carries the full set once snapshots resume.

## Updating the README summary

The four-row summary inside the `<!-- BENCHMARKS:start -->` /
`<!-- BENCHMARKS:end -->` markers in the project root `README.md` is
hand-curated at release prep, NOT auto-rendered. The "always fresh"
promise lives at the chart page
(<https://elijahr.github.io/lockfreequeues/latest/benchmarks/>); the
README values may lag by up to one release cycle.

**Procedure (run once per release PR):**

1. Open the latest devel snapshot at
   <https://elijahr.github.io/lockfreequeues/dev/benchmarks/>.
2. Read the throughput chart for these four shapes:
   - `lockfreequeues_sipsic/spsc/1p1c`
   - `lockfreequeues_sipmuc/mpmc/1p2c`
   - `lockfreequeues_mupsic/mpsc/2p1c`
   - `lockfreequeues_mupmuc/mpmc/2p2c`
3. Edit `README.md` between the BENCHMARKS markers, replacing the four
   `_to be filled at next release_` cells with the rounded throughput
   values (one decimal). Keep the table layout unchanged.
4. Commit the edit on the release branch as part of the release prep
   commit (CHANGELOG bump + version bump + README refresh).

Why hand-curated rather than auto-published: the README is the first
artefact most consumers see, so a regression on a noisy CI run should
NOT silently update it. The chart page absorbs run-to-run noise; the
README intentionally captures only the most recent release's headline
numbers.

The previous auto-render path (`benchmarks/render_readme.nim`,
removed in PR 5 of the bench-rollup) consumed the merged BMF JSON and
rewrote the markers in place. It was deleted because the "live"
audience now goes to the chart page, and the four-row README summary
is small enough that hand curation is faster than maintaining a
renderer.
