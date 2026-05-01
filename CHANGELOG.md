# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- New `benchmarks/nim/bench_common.nim` shared harness module exporting:
  `Topology` enum, `BMFEmitter` (alpha-sorted Bencher Metric Format JSON
  emission), `Histogram` (min-heap top-K + Algorithm R reservoir for
  stratified-percentile estimation, p99 within 1% of sort fallback on
  100k log-normal samples), generic `runThroughputHarness` and
  `runLatencyHarness` (1P/1C ping-pong RTT with monotonic-ns timing and
  per-run percentile aggregation), and Stats helpers (mean / stddev /
  minVal / maxVal / linear-interpolation percentile).
- Five new lockfreequeues adapters in `benchmarks/nim/adapters/`:
  `lockfreequeues_sipmuc_adapter.nim`, `lockfreequeues_mupsic_adapter.nim`,
  `lockfreequeues_unbounded_sipsic_adapter.nim`,
  `lockfreequeues_unbounded_sipmuc_adapter.nim`,
  `lockfreequeues_unbounded_mupmuc_adapter.nim`. Each exposes
  `topologiesSupported: set[Topology]` and the standard `push`/`pop`
  shape consumed by the shared harness. The unbounded adapters store
  the queue inline (not via `ptr`) to dodge a Nim 2.2.6 codegen bug
  triggered by generic-pointer destructor calls when bench_common is
  imported.
- New `benchmarks/merge_bmf.py` CLI: stateless union of per-binary BMF
  JSON fragments into a single output file. Exits 1 on `(slug, measure)`
  collisions naming both colliding inputs in stderr. Output slugs and
  measures alpha-sorted. Pure-stdlib (no third-party deps); covered by
  `benchmarks/tests/test_merge_bmf.py` (10 tests).
- `bench_throughput` `--bmf-out=<path>` flag emits Bencher Metric Format
  JSON natively. The flag is purely additive: with the flag absent, the
  binary is bit-for-bit unchanged from the prior release (same stdout
  text, same positional CLI: `bench_throughput sipsic mupmuc
  unbounded_mupsic channels`). Emitted slugs:
  `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_mupmuc/mpmc/{1,2,4,8}p{1,2,4,8}c`,
  `lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c`,
  `nim_channels/mpmc/{1,2,4}p{1,2,4}c`. Each carries a
  `throughput_ops_ms` measure with `value=mean`, `lower_value=mean-stddev`,
  `upper_value=mean+stddev`.
- Per-variant compile-time run-count overrides:
  `-d:BenchSipsicRuns=N`, `-d:BenchSipsicWarmup=N`,
  `-d:BenchMupmucRuns=N`, `-d:BenchMupmucWarmup=N`,
  `-d:BenchChannelsRuns=N`, `-d:BenchChannelsWarmup=N`. Defaults match
  the prior hard-coded `runs = 10`, so production runs are unchanged.
- `bench_latency` now emits Bencher Metric Format JSON natively via
  `--bmf-out=<path>`, mirroring `bench_throughput`'s CLI surface (PR 1).
  Positional args filter the variants run (`sipsic`, `mupmuc`, `sipmuc`,
  `mupsic`); without any positional arg, all four bounded lockfreequeues
  variants run at the 1p1c smoke shape. Emitted slugs:
  `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_sipmuc/mpmc/1p1c`,
  `lockfreequeues_mupsic/mpsc/1p1c`,
  `lockfreequeues_mupmuc/mpmc/1p1c`. Each carries
  `latency_p50_ns` / `latency_p95_ns` / `latency_p99_ns` measures
  (`latency_p999_ns` / `latency_max_ns` deferred to PR 6's threshold-
  gating work). The binary is built on top of
  `bench_common.runLatencyHarness` and uses per-binary intdefines:
  `-d:BenchLatencyRuns=N` (default 33), `-d:BenchLatencyMessageCount=N`
  (default 100_000), `-d:BenchLatencyWarmupRuns=N` (default 3).
- New `bench-latency` job in `.github/workflows/bench.yml` sibling to
  `bench-throughput`. Both jobs upload per-binary BMF artifacts
  (`bench-throughput-bmf` / `bench-latency-bmf`) consumed by a new
  `bench-upload` job that downloads via `actions/download-artifact@v4`
  pattern `bench-*-bmf`, runs `merge_bmf.py` to union the fragments,
  and performs the single `bencher run` upload that co-locates latency
  + throughput measures on shared per-slug histories. (Multiple
  `bencher run` invocations create separate Bencher Reports and would
  NOT co-locate measures — see merge rationale in design 1.)
- Four new topology-split throughput binaries replacing the legacy
  `bench_throughput.nim` (PR 2):
  `benchmarks/nim/bench_spsc.nim` (Sipsic 1p1c),
  `benchmarks/nim/bench_mpsc.nim` (Mupsic {1,2,4}p1c),
  `benchmarks/nim/bench_mpmc.nim` (Mupmuc {1,2,4}p{1,2,4}c plus 8p8c
    oversubscription, Sipmuc 1p{1,2,4}c, Nim channels {1,2,4}p{1,2,4}c),
  `benchmarks/nim/bench_unbounded.nim` (all four lockfreequeues
    unbounded variants at their natural shapes).
  Each emits BMF JSON via `--bmf-out=<path>` with the same per-slug
  `throughput_ops_ms` shape as the prior binary. Each owns its own
  per-binary intdefines (`-d:BenchSpscRuns/MessageCount/Warmup`,
  `-d:BenchMpscRuns/...`, `-d:BenchMpmcRuns/...`, plus four pairs of
  `-d:Unbounded<Variant>Runs/MessageCount` per design 2.5) so CI can
  budget each topology independently.
- New `benchmarks/scripts/superset_check.py`: slug-set deletion-safety
  guard that exits 0 when the post-split BMF covers every slug in the
  pre-split fixture (`tests/fixtures/pre-split-slugs.json`) and
  exits 1 with the missing slugs alpha-listed on stderr otherwise.
  Run by `bench-upload` immediately after `merge_bmf.py` so any
  silent slug regression introduced by future edits to the topology
  binaries fails the PR check. Covered by 9 unit tests in
  `benchmarks/tests/test_superset_check.py`.
- `benchmarks/tests/test_merge_bmf.py` gains `test_five_input_union`
  covering the upload-job pipeline shape: 5 sibling fragments (one per
  topology binary) merged via `merge_bmf.py` produce a single output
  whose slug set is the disjoint union, with shared slugs carrying
  measures from every input binary.

### Changed

- `bench_throughput.nim` now natively emits Bencher Metric Format JSON
  via `--bmf-out=<path>`. The CI workflow (`.github/workflows/bench.yml`)
  was rewired to consume the native output and feed it through
  `merge_bmf.py` before uploading to Bencher.dev — the previous Python
  regex parser (`bmf_adapter.py`) is gone.
- The four existing lockfreequeues adapter files renamed to the
  canonical `<library_slug>_adapter.nim` convention with `git mv`
  (history preserved): `lockfreequeues_sipsic.nim`,
  `lockfreequeues_mupmuc.nim`, `lockfreequeues_unbounded_mupsic.nim`.
  Each gained a `topologiesSupported: set[Topology]` constant for the
  upcoming PR 3 binary-split.
- `benchmarks/render_readme.nim` rewritten to consume the new BMF JSON
  shape directly (`{slug: {measure: MeasureValue}}`) instead of the
  legacy `bench_main` aggregator output. The slug walk decomposes
  `<lib>/<topology>/<P>p<C>c` back into the (impl, thread_config) pair
  the table renders.
- `benchmarks/runner.py` and `lockfreequeues.nimble` `task benchmarks`
  redirected from `bench_main` to `bench_throughput --bmf-out=<path>`.
- `benchmarks/README.md` rewritten to document the new flow
  (bench_common module, adapter convention, `--bmf-out` flag,
  merge_bmf.py, expected slug set).
- `benchmarks/nim/adapter.nim` now re-exports `PushResult` / `PopResult`
  from `bench_common` instead of defining its own copies, unifying the
  two parallel type definitions introduced by PR 0 Task 0.1. Both
  adapter packs (legacy `lockfreequeues_sipsic` / `lockfreequeues_mupmuc`
  / `channels` and the newer `lockfreequeues_sipmuc` / `mupsic` /
  `unbounded_*`) now flow through the same `runLatencyHarness` and
  `runThroughputHarness` without per-call-site type conversion. No
  external API change: legacy callers that imported `./adapter` for
  `PushResult` / `PopResult` continue to compile (PR 1).
- `.github/workflows/bench.yml` now runs the five topology-split
  binaries (`bench_spsc`, `bench_mpsc`, `bench_mpmc`, `bench_unbounded`,
  `bench_latency`) as a GitHub Actions matrix instead of the legacy
  pair of bench-throughput / bench-latency jobs. Each matrix entry
  has its own `timeout-minutes: 12` budget so a hang in one binary
  cannot burn the entire workflow's clock; the surviving binaries
  finish, the bench-upload job merges what arrived, and the operator
  gets partial Bencher coverage rather than no coverage. The
  bench-upload job now also runs the `superset_check.py` deletion-
  safety guard between `merge_bmf.py` and `bencher run` (PR 2).
- `benchmarks/runner.py` and `lockfreequeues.nimble` `task benchmarks`
  iterate the five topology-split binaries and merge their fragments
  via `merge_bmf.py` (PR 2).
- `benchmarks/README.md` rewritten to describe the 5-binary pipeline
  (matrix CI job, per-binary intdefines, deletion-safety guard, the
  merged BMF schema where one slug can carry both throughput and
  latency measures) (PR 2).

### Removed

- `benchmarks/bmf_adapter.py` — Python regex parser that converted
  `bench_throughput` stdout text into BMF JSON. Replaced by native BMF
  emission via `--bmf-out=`.
- `benchmarks/test_bmf_adapter.py` — unit tests for the parser.
  Replaced by `benchmarks/tests/test_merge_bmf.py`.
- `benchmarks/nim/bench_main.nim` — aggregator binary that wrapped
  bench_throughput + bench_latency and produced a custom JSON shape.
  `bench_throughput` is now the canonical entry point.
- `benchmarks/nim/bench_throughput.nim` — single multi-topology
  throughput driver, replaced by the four topology-split binaries
  `bench_spsc`, `bench_mpsc`, `bench_mpmc`, and `bench_unbounded`.
  The pre-split slug fixture committed at
  `tests/fixtures/pre-split-slugs.json` plus the `superset_check.py`
  guard wired into bench.yml enforces that no slug from the legacy
  binary silently disappears across the split (PR 2).

## [4.1.0] - 2026-05-01

### Added

- **Auto-create constructors for unbounded MP/SP variants.** `newUnboundedMupmuc[S, T, MaxThreads](strategy)`, `newUnboundedSipmuc[S, T, MaxThreads](strategy)`, and `newUnboundedMupsic[S, T, MaxThreads](strategy)` (the last auto-registers the caller as the consumer). Each heap-allocates a private `DebraManager` owned by the queue; teardown happens inside the queue's `=destroy` after segment cleanup. The existing explicit-manager API (`addr manager`) is preserved for multi-queue setups that share a manager.
- **Auto-register `getProducer()` / `getConsumer()` overloads.** No-arg variants that call `registerThread` internally. Each call consumes one thread slot; threads using multiple queues with a shared manager should prefer the explicit-handle overloads.
- **Bidirectional client refcount on `DebraManager`** (via `nim-debra >= 0.5.0`). Queue constructors call `bindClient`; `=destroy` calls `unbindClient`. The manager's destructor asserts `clientCount == 0`, catching the case where a shared manager is destroyed before its queues.

### Changed

- Bump minimum `debra` to 0.5.0.
- Bump minimum `typestates` to 0.6.0.
- `src/lockfreequeues/atomic_dsl.nim` no longer defines a local `compareExchange` shim — it's now provided by `debra/atomics`.

### Documentation

- `README.md` "Thread safety" section rewritten with the correct explanation of why `ref` items are rejected (`=copy`/`=sink` hooks race on slot refcounts in the shared `array[S, T]`), replacing the prior incorrect spinlock claim.
- "Choosing a queue" table split into separate Bounded and Unbounded tables for better rendering.
- The same `{.error.}` strings inside `unbounded_*.nim` were updated to match.

### Fixed

- `docs/api/epoch.md` removed (referenced a module extracted into `nim-debra`); was breaking the `mkdocs build` step in the docs deploy workflow.
- `.github/workflows/docs.yml` triggers extended to include `devel` branch and `workflow_dispatch`.

## [4.0.0] - 2026-04-30

### BREAKING

- Bounded MPMC/SPMC/MPSC slot protocol switched to per-slot sequence counters (Vyukov bounded-MPMC). Fixes a confirmed race that allowed two consumers to claim the same physical slot across generations, producing silent duplicate-item delivery and producer-vs-producer storage races. The race was TSAN-confirmed at 100% reproduction and ran at roughly a 5% release-mode duplicate rate under contention.
- `Mupmuc`, `Mupsic`, `Sipmuc` types: the `committed*`, `reservedHead*`, `reservedTail*`, and `storage*` fields have been removed. They are replaced with `cells*: MPMCCellArrayN[N, T]`. Consumers introspecting these fields directly must migrate to the new accessors.
- `head` and `tail` cursors on the bounded queue types are now `Atomic[uint64]` instead of `Atomic[int]`. Code reading these via `.load(...)` will need an explicit cast or a local rename.
- Bulk `push(items)` / `pop(count)` semantics have changed. The previous implementation performed an atomic block-claim across the requested range; the new implementation performs a best-effort fill via a loop of singleton operations. Partial completion is reported through the existing `Option[Slice[int]]` / `Option[seq[T]]` return types, so the API surface is unchanged but the intra-call atomicity guarantee is gone.
- `CommittedFlagsN` type removed. Replaced with `SlotSeqN`, `MPMCCellPayload`, and `MPMCCellArrayN`. The `tests/t_committed_flags_n.nim` file has been deleted; equivalent and stronger coverage lives in `tests/t_slot_seq_n.nim`.

### Added

- New `lockfreequeues/backoff` module with `backoffOnRetry` (exponential) and `backoffOnPeerWait` (cpuPause-only) helpers. Used internally on CAS-retry paths to handle CPU oversubscription without burning unbounded CPU.
- Bench harness now supports the `Mupmuc` 8P/8C topology. The previous topology table was implicitly capped at 4P/4C.
- New `LFQ_STRESS_DURATION_SEC` environment variable on threaded stress tests, for sustained-load runs beyond the default iteration budget.
- New `tests/t_slot_seq_generation_rollover.nim`: a deterministic single-threaded reproduction of the original protocol-bug scenario, asserting that the new sequence-counter protocol rejects the stale second-consumer claim.
- Throughput bench harness for `UnboundedMupsic` (1P/1C, 2P/1C, 4P/1C) at `benchmarks/nim/bench_throughput.nim` plus a thin adapter at `benchmarks/nim/adapters/lockfreequeues_unbounded_mupsic.nim` that owns the queue and `DebraManager`. Producer threads register their own `ThreadHandle` in-thread (handles are per-thread by construction). The new variants run for 33 timed iterations + 3 warmup; existing Sipsic/Mupmuc/Channels run counts are unchanged.
- `bench_throughput` accepts variant-group args (`sipsic`, `mupmuc`, `unbounded_mupsic`, `channels`) to limit which benchmarks run. With no args, all variants run (backward compatible). Multiple args take the union of groups. Unknown args print the supported list and exit non-zero. Lets gate runs target a single queue family without paying for the slow bounded MPMC variants.
- Compile-time overrides for `bench_throughput` run shape via `{.intdefine.}` constants: `-d:MessageCount=N`, `-d:DefaultRuns=N`, `-d:WarmupRuns=N`, `-d:UnboundedMupsicRuns=N`, `-d:UnboundedMupsicSegmentSize=N`, `-d:UnboundedMupsicMaxThreads=N`. Defaults are unchanged (1M messages, 33 runs, 3 warmup). Lets gate runs trade statistical confidence for wall-clock budget without source edits. `bench_throughput` also unbuffers stdout in `isMainModule` so progress is visible under file redirect.

### Fixed

- Mupmuc 4P/4C livelock under CPU oversubscription. The combination of new backoff helpers and monotonic per-thread retry counters resolves the scheduler-pressure livelock; the bounded queue can now run 8 contending threads on 4 vCPUs without hangs.
- Bench harness `messageCount div P` truncation bug. Consumers waited forever for items the integer-division truncation had silently discarded. Spread-the-remainder fix applied in three places.
- Several pre-existing breakages in the unbounded threaded stress tests. The 3.2.0 DEBRA migration left them on a deleted `EpochManager` API; the tests have been updated to the current handle-based API. A small number remain disabled pending separate cleanup.

### Changed

- Bounded queue documentation updated to reflect the new sequence-counter publication protocol. Unbounded queue documentation now explicitly disambiguates the segment-local committed-flag protocol from the bounded sequence-counter protocol. See `docs/safety-model.md` and `docs/slot-ownership-typestates.md`.

## [3.2.0] - 2026-04-27

### Added

- New queue types:
  - `Sipmuc`: bounded single-producer, multi-consumer queue.
  - `UnboundedSipsic`: segmented unbounded single-producer, single-consumer queue (no reclamation needed).
  - `UnboundedSipmuc`: segmented unbounded single-producer, multi-consumer queue with DEBRA reclamation.
  - `UnboundedMupsic`: segmented unbounded multi-producer, single-consumer queue with DEBRA reclamation.
  - `UnboundedMupmuc`: segmented unbounded multi-producer, multi-consumer queue with DEBRA reclamation.
  - Segment storage uses libc `c_calloc` / `c_free` (via `system/ansi_c`); a nil return from `c_calloc` raises `OutOfMemDefect`. Avoids the cross-thread free hazard from Nim's `allocShared`, which routes through per-thread heap metadata.
  - The consumer-visible head pointer is `Atomic[ptr Segment]` and is CAS-advanced past exhausted segments; the CAS winner retires the old segment via DEBRA.
- Typestate-driven push and pop modules under `src/lockfreequeues/typestates/` for both bounded and unbounded queues. The high-level queue APIs now build on these typestate transitions.
- `DeallocationStrategy` (`Manual` / `Eager`) on the unbounded queues, configured at queue construction. `Eager` retires and immediately attempts reclamation per pop; `Manual` accumulates retired segments for an external `tryReclaim` call. Default is `Eager`, except `Manual` under `--gc:none`.
- Compile-time `-d:LockFreeQueuesAdvanceEvery=N` (default 64) to tune the per-pop epoch-advance cadence in the unbounded queue retirement paths.
- Compile-time lock-free check for queue item types: arc/orc compilation errors when a queue holds `ref` items (which fall back to spinlock refcounting on those memory managers). Opt out with `-d:allowNonLockFreeQueueItems`.
- Threaded reclamation tests for all four unbounded queue variants (`t_unbounded_*_threaded`), exercised under arc, orc, and refc, plus the TSAN and ASAN sanitizer matrix.
- Latency and throughput benchmark suite under `benchmarks/nim/` (`bench_latency.nim`, `bench_throughput.nim`, `bench_main.nim`) with adapters for each queue type.
- New examples: `audio_buffer.nim`, `event_collector.nim`, `job_scheduler.nim`, `task_fanout.nim`, and `sipmuc.nim`.
- Thread safety section and slot-ownership typestate documentation in README.
- CI matrix across arc, orc, and refc memory managers, including a `-d:nimEnforceLockFreeAtomics` lane.
- Dependency on `debra >= 0.3.0` for safe memory reclamation in the unbounded multi-consumer queues.
- Dependency on `typestates >= 0.3.1` (already used; bumped to pull in the latest API).

### Changed

- Eager-strategy unbounded queues now gate `reclaimNow` on `advanceEvery` returning `true`, eliminating per-pop epoch-safety atomic loads when the global epoch hasn't advanced. Reclamation latency is bounded by `LockFreeQueuesAdvanceEvery` (default 64), the same cadence the user already controls.
- Bounded queues (`Sipsic`, `Mupsic`, `Mupmuc`) reimplemented on the typestate layer. SPSC uses N+1 storage slots to distinguish empty from full; MPSC, SPMC, and MPMC use N storage slots paired with per-slot committed flags so producers can publish before consumers observe the slot. Surface API (push/pop, `head`/`tail`, capacity semantics) is unchanged for SPSC; the multi-producer / multi-consumer variants gain a published-before-visible ordering guarantee they did not previously provide.
- `atomic_dsl.nim` now re-exports `debra/atomics` instead of wrapping `std/atomics`. Call-site DSL (`relaxed`, `acquire`, `release`, `sequential`) is unchanged.
- Stress test runner exercises all three memory managers.

### Removed

- `std/atomics` dependency. `Atomic[T]` and the memory-order primitives are now sourced from `debra/atomics`.
- `src/lockfreequeues/constants.nim`. `CacheLineBytes` is now sourced from `debra/atomics`.
- Removed the internal `lockfreequeues/ops` submodule. It was documented as internal, had no callers inside the library, and its `index` helper had silently shifted from `value mod capacity` (3.1.0) to `value mod (capacity + 1)` during the queue refactor. External code that imported `lockfreequeues/ops` directly should migrate to the public typestate API or inline the small helpers it contained.

## [3.1.0] - 2024-09-28

### Changed

- Fixed wraparound issue in `full()`
- Drop support for Nim v1 due to compilation issue with atomics.

## [3.0.0] - 2021-12-14

### Added

- README link to Gitter chat room.

### Changed

- Regenerate documentation on PR merge.
- Test against Nim 1.6.0.
- Convert `NoConsumersAvailableDefect` and `NoProducersAvailableDefect` to `CatchableErrors`; there might be some value in catching them.

### Removed

## [2.1.0] - 2021-07-19

### Added

### Changed

- Use correct memory orderings, as reported in https://github.com/elijahr/lockfreequeues/issues/6
- Move changelog from README.md to CHANGELOG.md

### Removed

## [2.0.6] - 2021-01-25

### Added

### Changed

- Fix issue with htmldocs submodule during `nimble install lockfreequeues`.

### Removed

## [2.0.5] - 2021-01-06

### Added

### Changed

- Moved from Travis CI to GitHub Actions.

### Removed

## [2.0.4] - 2020-08-10

### Added

- Multi-producer, single-consumer queue (Mupsic)
- Multi-producer, multi-consumer queue (Mupmuc)
- Nicer examples

### Changed

- Refactor
- Fix wrap-around bug, improve test coverage

### Removed

- Shared memory queues

## [1.0.0] - 2020-07-06

### Added

### Changed

- Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
- `head` and `tail` are now in the range `0 ..<2*capacity`
- `capacity` doesn’t have to be a power of two
- Use `align` pragma instead of padding array

### Removed

## [0.1.0] - 2020-07-02

### Added

- Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`

### Changed

### Removed
