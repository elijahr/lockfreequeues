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
var q1 = newUnboundedSipsic[64, int]()
var q2 = newUnboundedSipsic[64, uint64]()
var q3 = newUnboundedSipsic[64, pointer]()

type NodeObj = object
  value: int
var q4 = newUnboundedSipsic[64, ptr NodeObj]()

# This fails on arc/orc — `ref` uses spinlocks for refcounting.
type Node = ref object
  value: int
var q5 = newUnboundedSipsic[64, Node]()  # Compile error
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
  platform-dependent; verify on your deployment target with
  `-d:nimEnforceLockFreeAtomics`.

### Testing under multiple memory managers

```bash
nim c -r --mm:refc tests/mytest.nim
nim c -r --mm:arc  tests/mytest.nim
nim c -r --mm:orc  tests/mytest.nim
```

## Queue-level guarantees

- **Bounded queues** (`Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`) are ring buffers
  with compile-time capacity. SPSC operations are wait-free; SPMC, MPSC, and
  MPMC variants are lock-free on the contended side.
- **Unbounded queues** (`UnboundedSipsic`, `UnboundedSipmuc`,
  `UnboundedMupsic`, `UnboundedMupmuc`) are linked segments. The unbounded
  multi-thread variants use [DEBRA](https://github.com/elijahr/nim-debra) to
  reclaim retired segments safely.
- All multi-producer / multi-consumer queues publish a slot's data with a
  release store *before* the slot becomes visible to consumers, via the
  `committed` flag (or analogue). Consumers always observe a fully-written
  slot.

## Test matrix

CI runs the full suite across:

- Runners: `ubuntu-24.04` (x86_64), `ubuntu-24.04-arm` (native arm64),
  `macos-latest` (arm64).
- Memory managers: `arc`, `orc`, `refc`, `atomicArc`.
- Backends: C and C++.
- Sanitisers: ThreadSanitizer (TSAN) under `atomicArc`, AddressSanitizer (ASAN).
- Lock-free atomic enforcement: a dedicated `-d:nimEnforceLockFreeAtomics` lane
  on both `arc` and `orc` to catch any spinlock fallback.

The same matrix is applied to the threaded reclamation tests
(`t_unbounded_*_threaded`) so segment retirement and free are exercised under
contention plus sanitisers.
