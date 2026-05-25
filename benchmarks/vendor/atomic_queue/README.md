# Vendored: `atomic_queue` (max0x7ba)

This directory vendors Maxim Egorushkin's `atomic_queue` header-only C++
library so the v4.2.0 bench suite can compare `lockfreequeues` against a
high-performance bounded MPMC ring buffer without depending on a system
package or a network fetch at build time.

## Pinned upstream

- **Upstream repo:** <https://github.com/max0x7ba/atomic_queue>
- **Pinned commit:** `1a3774a89c86ecfdf08753dbd41018ace5a833a4`
  (head of upstream `master` on the v4.2.0 vendoring date).
- **License:** MIT (see `LICENSE` in this directory).

## What is vendored

| File                                           | Origin                                        |
| ---------------------------------------------- | --------------------------------------------- |
| `include/atomic_queue/atomic_queue.h`          | upstream at the pinned commit                 |
| `include/atomic_queue/atomic_queue_mutex.h`    | upstream at the pinned commit                 |
| `include/atomic_queue/barrier.h`               | upstream at the pinned commit                 |
| `include/atomic_queue/defs.h`                  | upstream at the pinned commit                 |
| `include/atomic_queue/spinlock.h`              | upstream at the pinned commit                 |
| `LICENSE`                                      | upstream at the pinned commit                 |
| `atomic_queue_wrapper.cpp`                     | original `lockfreequeues` source (Apache-2.0) |
| `README.md`                                    | original `lockfreequeues` source (this file)  |

The five headers are the entire `include/atomic_queue/` directory in
upstream; `atomic_queue.h` includes the other four via `#include "..."`,
so the closure is complete.

## Why vendor and not a system package

`atomic_queue` is header-only and is not packaged by the major Linux
distributions. Vendoring at a pinned SHA gives:

- reproducible bench builds across CI runs and developer workstations,
- no network dependency on GitHub during `bench.yml` (the soft-skip
  install step is a `test -f` on the vendored header),
- a single, auditable point of upgrade.

## Upgrade procedure

1. Pick the desired upstream commit SHA (prefer a tagged release if one
   exists; fall back to the head of `master` and record the SHA verbatim).
2. From a scratch directory:
   ```bash
   git clone https://github.com/max0x7ba/atomic_queue atomic_queue-upstream
   cd atomic_queue-upstream
   git checkout <new-sha>
   git rev-parse HEAD
   ```
3. Copy the new headers and license into this directory:
   ```bash
   cp include/atomic_queue/*.h <repo>/benchmarks/vendor/atomic_queue/include/atomic_queue/
   cp LICENSE <repo>/benchmarks/vendor/atomic_queue/
   ```
4. Update the **Pinned commit** line above and the **Version** line in
   the project root `THIRD_PARTY_LICENSES.md` `atomic_queue` block.
5. Re-run the smoke compile and bench binaries that link the adapter:
   ```bash
   nim cpp -d:release --threads:on \
     -d:adapter_atomic_queue_available \
     benchmarks/nim/smoke/smoke_atomic_queue.nim
   ```
6. If upstream changed the public API of `AtomicQueueB<T>` (`try_push` /
   `try_pop` / destructor), update `atomic_queue_wrapper.cpp` to match
   before committing.

## Why the `extern "C"` wrapper

`atomic_queue.h` is heavily templated (CRTP base classes parameterised
on cache-line size, throughput, and total-order flags). Importing it
directly into a Nim adapter via `importcpp` would expose the Nim adapter
to upstream's template machinery and force every `nim cpp` invocation
that consumes the adapter to recompile the world.
`atomic_queue_wrapper.cpp` reduces the API surface to four non-template,
`uint64_t`-payload functions (`aq_init` / `aq_push` / `aq_pop` /
`aq_destroy`); the adapter imports those via plain `importc`. Same
pattern as `benchmarks/vendor/concurrentqueue/moodycamel_wrapper.cpp`.

## NIL sentinel offset

`AtomicQueueB<T>` reserves the default-constructed `T` value as a NIL
sentinel marking empty slots; for `uint64_t` that sentinel is 0. The
bench harness pushes payloads in the natural range `[0, messageCount)`,
which would collide with the sentinel. The wrapper offsets every
pushed value by `+1` and undoes the offset on pop, so the on-the-wire
range is `[1, UINT64_MAX]` while the bench harness sees `[0,
UINT64_MAX-1]`. The bench harness never pushes `UINT64_MAX`, so the
offset is collision-free. See `atomic_queue_wrapper.cpp` for the inline
rationale.
