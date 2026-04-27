# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
