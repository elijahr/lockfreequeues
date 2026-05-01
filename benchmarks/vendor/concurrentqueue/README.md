# Vendored: MoodyCamel `concurrentqueue`

This directory vendors a single-header release of Cameron Desrochers'
`concurrentqueue` library so the bench suite can compare
`lockfreequeues` against an industry-standard MPMC unbounded queue
without depending on a system package or a network fetch at build time.

## Pinned upstream

- **Upstream repo:** <https://github.com/cameron314/concurrentqueue>
- **Pinned commit:** `d655418bb644b7f85159d94c591d7d983949fb81`
  (clone date: 2026-05-01; vendored as the head of the upstream
  default branch on that day).
- **License:** dual-licensed BSD-2-Clause / Boost Software License 1.0
  (see `LICENSE.md` in this directory).

## What is vendored

| File                  | Origin                                              |
| --------------------- | --------------------------------------------------- |
| `concurrentqueue.h`   | upstream `concurrentqueue.h` at the pinned commit   |
| `LICENSE.md`          | upstream `LICENSE.md` at the pinned commit          |
| `moodycamel_wrapper.cpp` | original `lockfreequeues` source (Apache-2.0)    |
| `README.md`           | original `lockfreequeues` source (this file)        |

`moodycamel_wrapper.cpp` is **not** vendored; it is a thin
`extern "C"` shim that isolates the Nim bench adapter from
`concurrentqueue`'s template machinery. See
`benchmarks/nim/adapters/moodycamel_adapter.nim` for how it is consumed.

## Why vendor and not `apt install`

`concurrentqueue` ships only as a single header and is not packaged by
the major Linux distributions. Vendoring at a pinned SHA gives:

- reproducible bench builds across CI runs and developer workstations,
- no network dependency on GitHub during `bench.yml` (the soft-skip
  install step is a `test -f` on the vendored header),
- a single, auditable point of upgrade.

## Upgrade procedure

1. Pick the desired upstream commit SHA. Prefer a tagged release if
   one exists; fall back to the head of `master` and record the SHA
   verbatim.
2. From a scratch directory:
   ```bash
   git clone https://github.com/cameron314/concurrentqueue concurrentqueue-upstream
   cd concurrentqueue-upstream
   git checkout <new-sha>
   git rev-parse HEAD
   ```
3. Copy the new header and license into this directory:
   ```bash
   cp concurrentqueue.h <repo>/benchmarks/vendor/concurrentqueue/
   cp LICENSE.md       <repo>/benchmarks/vendor/concurrentqueue/
   ```
4. Update the **Pinned commit** line in this README and the
   **Version** line in the project root `THIRD_PARTY_LICENSES.md`
   `concurrentqueue (MoodyCamel)` block to the new SHA.
5. Re-run the bench-adapter smoke and the bench binaries that link the
   adapter; record the diff in the upgrade PR description:
   ```bash
   nim cpp -d:release --threads:on \
     -d:adapter_moodycamel_available \
     benchmarks/nim/smoke/smoke_moodycamel.nim && ./smoke_moodycamel
   ```
6. If upstream changed the public API of
   `moodycamel::ConcurrentQueue<T>` (`enqueue` / `try_dequeue` /
   destructor), update `moodycamel_wrapper.cpp` to match before
   committing.

## Why the `extern "C"` wrapper

`concurrentqueue.h` is a heavily templated C++ header. Importing it
directly into a Nim adapter via `importcpp` would expose the Nim
adapter to upstream's template machinery and force every `nim cpp`
invocation that consumes the adapter to recompile the world.
`moodycamel_wrapper.cpp` reduces the API surface to four
non-template, `uint64_t`-payload functions
(`mc_init` / `mc_push` / `mc_pop` / `mc_destroy`); the adapter
imports those via plain `importc`. Risk M5 in the
`bench-rollup` understanding doc captures this rationale in detail.
