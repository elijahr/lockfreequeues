# Vendored: `rigtorp::SPSCQueue`

This directory vendors Erik Rigtorp's `SPSCQueue` single-header C++
library so the v4.2.0 bench suite can compare `lockfreequeues` against a
canonical bounded SPSC ring buffer without a system-package dependency
or a network fetch at build time.

## Pinned upstream

- **Upstream repo:** <https://github.com/rigtorp/SPSCQueue>
- **Pinned commit:** `1053918dbd251fbff69b24ef27fa5d51c29ec2af`
  (head of upstream `master` on the v4.2.0 vendoring date).
- **License:** MIT (see `LICENSE` in this directory).

## What is vendored

| File                                | Origin                                        |
| ----------------------------------- | --------------------------------------------- |
| `include/rigtorp/SPSCQueue.h`       | upstream at the pinned commit                 |
| `LICENSE`                           | upstream at the pinned commit                 |
| `rigtorp_spsc_wrapper.cpp`          | original `lockfreequeues` source (Apache-2.0) |
| `README.md`                         | original `lockfreequeues` source (this file)  |

`SPSCQueue.h` is single-header with no transitive includes outside the
C++ standard library.

## Why vendor

Same rationale as `benchmarks/vendor/concurrentqueue/`: the library is
not packaged by major Linux distributions, so vendoring at a pinned SHA
gives reproducible bench builds and a single auditable upgrade point.

## Upgrade procedure

1. Pick the desired upstream commit SHA.
2. From a scratch directory:
   ```bash
   git clone https://github.com/rigtorp/SPSCQueue SPSCQueue-upstream
   cd SPSCQueue-upstream
   git checkout <new-sha>
   git rev-parse HEAD
   ```
3. Copy the new header and license:
   ```bash
   cp include/rigtorp/SPSCQueue.h <repo>/benchmarks/vendor/rigtorp_spsc/include/rigtorp/
   cp LICENSE <repo>/benchmarks/vendor/rigtorp_spsc/
   ```
4. Update the **Pinned commit** line above and the **Version** line in
   the project root `THIRD_PARTY_LICENSES.md` `rigtorp_spsc` block.
5. Re-run the smoke compile:
   ```bash
   nim cpp -d:release --threads:on \
     -d:adapter_rigtorp_spsc_available \
     benchmarks/nim/smoke/smoke_rigtorp.nim
   ```
6. If upstream changed the public API of `SPSCQueue<T>` (`try_push` /
   `front` / `pop` / destructor), update `rigtorp_spsc_wrapper.cpp` to
   match before committing.

## Why the `extern "C"` wrapper

Same pattern as `benchmarks/vendor/concurrentqueue/`: `SPSCQueue.h` is
templated; the wrapper reduces the API surface to four non-template,
`uint64_t`-payload functions consumed by the Nim adapter via `importc`.
