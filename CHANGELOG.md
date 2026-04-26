# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.2.0] - 2026-04-25

### Added

- New queue implementations
  - `Sipmuc`: bounded single-producer, multi-consumer queue
  - `UnboundedSipsic`: single-producer, single-consumer (no reclamation needed)
  - `UnboundedSipmuc`: single-producer, multi-consumer with DEBRA reclamation
  - `UnboundedMupsic`: multi-producer, single-consumer with DEBRA reclamation
  - `UnboundedMupmuc`: multi-producer, multi-consumer with DEBRA reclamation
- Typestate-driven push and pop operation modules under `src/lockfreequeues/typestates/`
- Compile-time lock-free type checking for queue item types
  - Errors on `ref` item types under arc/orc (which fall back to spinlock refcounting)
  - Opt-out via `-d:allowNonLockFreeQueueItems`
- Threaded reclamation tests for all four unbounded queue variants (`t_unbounded_*_threaded`), exercised under arc, orc, refc, and the TSAN/ASAN matrix
- Thread safety section and slot-ownership typestate documentation in README
- CI matrix across arc, orc, refc memory managers
- CI matrix with `-d:nimEnforceLockFreeAtomics`

### Changed

- `atomic_dsl.nim` now re-exports `debra/atomics` instead of wrapping `std/atomics`. The call-site DSL is unchanged.
- Unbounded queue retirement sites now use `withPin` plus `retireBatch` from nim-debra's batched retire API instead of explicit typestate transitions.
- `headSegment` and related segment-pointer fields are `Atomic[ptr Segment]` and are advanced via CAS before the previous segment is retired.
- Segment storage uses libc `c_calloc` / `c_free` instead of `allocShared0` / `deallocShared` to avoid TLS-routed cross-thread allocator issues.
- Test suite runs across arc, orc, refc memory managers.
- Test suite verifies lock-free enforcement with `-d:nimEnforceLockFreeAtomics`.
- Stress tests updated with memory manager variants.
- Dependencies: `typestates >= 0.3.1`, `debra >= 0.3.0`.

### Removed

- `std/atomics` dependency.
- `src/lockfreequeues/constants.nim`. `CacheLineBytes` is now sourced from `debra/atomics`.

### Fixed

- Eager reclamation no-op in unbounded queues: pops now call `advanceEvery(64)` so the global epoch actually advances and reclamation can fire.
- Use-after-free under concurrent reclamation in unbounded queues: `headSegment` is now atomic and CAS-advanced before retirement, so consumers cannot read a freed segment pointer.
- refc use-after-free in `unbounded_sipsic`'s inline reclamation path (resolved by the `headSegment` fix above).

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
