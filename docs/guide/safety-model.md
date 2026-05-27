# Safety Model

This document covers the thread-safety contract of `lockfreequeues`: what the
queues guarantee, what they require of item types, and how the test matrix
exercises both.

For the slot-level state machine that backs push and pop, see
[slot-ownership-typestates.md](slot-ownership-typestates.md).

## Item type requirements

By default, `lockfreequeues` requires queue item types to be lock-free.

```nim
import lockfreequeues

# These work — lock-free types.
var q1 = newUnboundedSpscQueue[int, stEager, 64, 4]()
var q2 = newUnboundedSpscQueue[uint64, stEager, 64, 4]()
var q3 = newUnboundedSpscQueue[pointer, stEager, 64, 4]()

type NodeObj = object
  value: int
var q4 = newUnboundedSpscQueue[ptr NodeObj, stEager, 64, 4]()

# This fails on arc/orc — `ref` uses spinlocks for refcounting.
type Node = ref object
  value: int
var q5 = newUnboundedSpscQueue[Node, stEager, 64, 4]()  # Compile error
```

### Why this matters

On `arc` and `orc` memory managers, `ref` types use reference counting. The
queue's CAS operations correctly serialize slot access, but reference-counting
operations on `ref` items may fall back to spinlock-based atomics on some
platforms. That defeats the lock-free guarantee at the item level even when
the queue itself stays lock-free.

### Allowing non-lock-free types

If you understand the trade-offs and need to use non-lock-free types:

```bash
nim c -d:allowNonLockFreeQueueItems your_program.nim
```

### Recommended patterns

For maximum safety and portability:

- **Value types**: `int`, `uint64`, `float`, enums, simple `object`.
- **Pointers**: `ptr T` when you need indirection — you manage lifetime.
- **Avoid `ref` types** on `arc` / `orc`; prefer `ptr T` with manual memory
  management.
- **Test on the target platform**: lock-free atomic availability is
  platform-dependent. `debra/atomics` rejects non-lock-free `Atomic[T]`
  by default; build on your deployment target to surface any rejection,
  or pass `-d:debraAllowNonLockFreeAtomics` to opt into the libatomic
  spinlock fallback (with a per-call-site warning).

### Testing under multiple memory managers

```bash
nim c -r --mm:refc tests/mytest.nim
nim c -r --mm:arc  tests/mytest.nim
nim c -r --mm:orc  tests/mytest.nim
```

## Queue-level guarantees

- **Bounded queues** (the `BQueue` generic, via `newSpscQueue` /
  `newSpmcQueue` / `newMpscQueue` / `newMpmcQueue`) are ring buffers
  with compile-time capacity. SPSC operations are wait-free; SPMC, MPSC, and
  MPMC shapes are lock-free on the contended side.
- **Unbounded queues** (the `Queue` generic, via `newUnboundedSpscQueue` /
  `newUnboundedSpmcQueue` / `newUnboundedMpscQueue` /
  `newUnboundedMpmcQueue`) are linked segments. The multi-cardinality
  unbounded shapes use [DEBRA](https://github.com/elijahr/nim-debra) to
  reclaim retired segments safely.
- All multi-producer / multi-consumer queues publish a slot's data with a
  release store *before* the slot becomes visible to consumers. Consumers
  always observe a fully-written slot.
  - **Bounded multi-cardinality shapes** (SPMC, MPSC, MPMC) use per-slot
    sequence counters following the Vyukov bounded-MPMC protocol. Each slot
    carries an `Atomic[uint64]` whose value encodes both the slot's
    generation and its producer/consumer phase. Producers and consumers CAS
    the head/tail cursor only when the target slot's sequence counter matches
    the expected generation, which makes generation-rollover races
    structurally impossible (a stale claimant from a previous generation
    cannot win the CAS against a current-generation slot).
  - **Unbounded multi-cardinality shapes** (SPMC, MPSC, MPMC) retain the
    per-slot `committed` flag inside each segment. Segments are single-use
    linked nodes (no generation rollover), so the simpler one-shot committed
    flag is sufficient.

## Test matrix

CI runs the full suite across:

- Runners: `ubuntu-24.04` (x86_64), `ubuntu-24.04-arm` (native arm64),
  `macos-latest` (arm64).
- Memory managers: `arc`, `orc`, `refc`, `atomicArc`.
- Backends: C and C++.
- Sanitisers: ThreadSanitizer (TSAN) under `atomicArc`, AddressSanitizer (ASAN).

Lock-free atomic enforcement is structural, not lane-specific: `debra/atomics`
rejects any non-lock-free `Atomic[T]` at compile time on every lane by default.

The same matrix is applied to the threaded reclamation tests
(`t_unbounded_*_threaded`) so segment retirement and free are exercised under
contention plus sanitisers.
