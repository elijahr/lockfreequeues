# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added

### Changed
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
