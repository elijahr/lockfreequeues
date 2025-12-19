# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.2.0] - 2025-12-18

### Added

- Unbounded queue implementations with DEBRA epoch-based reclamation
  - `UnboundedSipsic` - Single-producer, single-consumer (no DEBRA needed)
  - `UnboundedSipmuc` - Single-producer, multi-consumer
  - `UnboundedMupsic` - Multi-producer, single-consumer
  - `UnboundedMupmuc` - Multi-producer, multi-consumer
- Typestate-enforced push/pop operations for all unbounded queues
- Compile-time lock-free type checking for queue item types
  - Errors on `ref` types with arc/orc (uses spinlocks for refcounting)
  - Use `-d:allowNonLockFreeQueueItems` to opt-out
- Thread safety documentation in README
- Slot-ownership typestates documentation
- CI testing with multiple memory managers (arc, orc, refc)
- CI testing with `-d:nimEnforceLockFreeAtomics` flag

### Changed

- Test suite now runs with arc, orc, refc memory managers
- Test suite now verifies lock-free enforcement
- Stress tests updated with MM variants
- Dependencies updated: `typestates >= 0.3.1`, `debra >= 0.2.0`

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
