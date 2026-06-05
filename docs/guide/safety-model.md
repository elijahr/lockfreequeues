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

# This fails on arc/orc/atomicArc — see below for why.
type Node = ref object
  value: int
var q5 = newUnboundedSpscQueue[Node, stEager, 64, 4]()  # Compile error
```

### Why this matters

Slots are stored in a shared `array[S, T]` and crossed between producer and
consumer threads. When a producer writes `seg.data[i] = item` and a consumer
reads `seg.data[i]`, those assignments fire Nim's `=copy`/`=sink` hooks for
ref types, which mutate the refcount on the same object that other threads
are concurrently reading or writing.

On `arc` and `orc`, that refcount is a non-atomic `int` — concurrent mutation
is a data race regardless of any lock-free property. On `atomicArc` the
refcount itself is atomic, but the slot bytes (the ref handle) are still
read and written without coordination beyond the queue's CAS protocol, so
the race surfaces as torn slot reads or as refcount mutation around a
partially-written slot. In every case the queue itself remains lock-free;
the unsoundness is in the item-type contract.

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
  - **Unbounded multi-cardinality shapes** (SPMC, MPSC) retain the
    per-slot `committed` flag inside each segment. Segments are single-use
    linked nodes (no generation rollover), so the simpler one-shot committed
    flag is sufficient.
  - **Unbounded MPMC** (v5.0.0 Phase B) is the exception: each cell is a
    strict-LCRQ `(seq, payload)` pair manipulated via DWCAS, per the LCRQ
    paper §4 close-CAS-on-empty progress rule. A consumer that observes an
    empty cell can race to publish a `closed` sentinel, which resolves the
    case-(b) consumer-reservation race in the pop fast-path. The `T`
    constraint (`supportsCopyMem(T) AND sizeof(T) <= sizeof(uint)`) is what
    keeps the cell single-DWCAS-word wide; see the Queue API page and the
    v5.0.0 migration doc Phase B section for details.

### Progress guarantees against stalled producers (unbounded MPMC)

The unbounded MPMC consumer makes **bounded** progress even when a producer
that has already reserved its tail slot is preempted (or dies) before it
publishes. The consumer's wait for an unpublished cell is bounded by
`MaxWaitForPublishSpins = 1024`; on budget exhaustion the consumer
escalates via `tryCloseOnEmpty`, which either closes the cell (consumer
moves on to the next claim) or accepts a just-in-time publish (consumer
completes its original claim). The §5.3 CLOSED-detection branch falls
through to the §5.2 slow-path inline-skip rather than short-circuiting to
eager segment retirement, so a segment with one closed cell and one
in-flight publish is never retired prematurely — `prevConsumerIdx`
advances on both successful claims AND skipped-closed cells, and retirement
is gated on full drain. The lock-free progress claim from the LCRQ paper
§4 is enforced, not aspirational.

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
