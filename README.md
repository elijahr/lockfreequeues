[![build](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml/badge.svg)](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml)

# lockfreequeues

Lock-free queues for Nim. Bounded queues are ring buffers; unbounded queues are
linked segments reclaimed via [DEBRA](https://github.com/elijahr/nim-debra).
All variants cover SPSC, SPMC, MPSC, and MPMC.

API documentation: <https://elijahr.github.io/lockfreequeues>

> **v5.0.0 breaking change.**
> v5.0.0 collapses the seven typestate queue families plus the standalone
> `UnboundedSpsc` into two generic types: `BQueue[T, ccProd, ccCons, N, P, C]`
> (bounded) and `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` (unbounded, with
> the `(ccSingle, ccSingle)` arm absorbing the standalone `UnboundedSpsc`
> body). Smart constructors collapse from 11 family-prefixed entry points to
> two generics (`newBQueue`, `newQueue`) plus family-named thin wrappers
> (`newSpscQueue`, `newMpscQueue`, `newUnboundedMpmcQueue`, …) for
> ergonomic continuity. See [`CHANGELOG.md`](CHANGELOG.md) for the v5.0.0
> reshape note with worked examples and the canonical surface reference.

## Why this library

If two threads need to hand items to each other and you cannot afford a mutex,
the answer is a lock-free queue. Picking the right one is the hard part: do you
have one producer or many, one consumer or many, a fixed capacity or not? Each
choice changes the algorithm and the cost. `lockfreequeues` covers all eight
cells of that grid (four bounded cardinality arms on `BQueue` and four
unbounded cardinality arms on `Queue`) with a uniform API and verified
ordering guarantees.

A short vocabulary first.

- **Wait-free**: every thread completes its operation in a bounded number of
  steps, regardless of what other threads do. The strongest progress guarantee.
- **Lock-free**: at least one thread makes progress on every step. Individual
  threads may retry, but the system never stalls.

Wait-free is preferable when you can get it; lock-free is what you get with
contended CAS loops. Both are stronger than mutex-based code, which can stall
the whole system if a holder is preempted.

## Installation

```sh
nimble install lockfreequeues
```

## Quick Start

v5.0.0 exposes two generic types. `BQueue[T, ccProd, ccCons, N, P, C]` is the
bounded ring buffer; `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` is the
unbounded linked-segment queue. The `ccProd` / `ccCons` parameters
(`ccSingle` / `ccMulti`) select the producer and consumer cardinality. For
ergonomic continuity each cell of the SPSC/SPMC/MPSC/MPMC grid has a
family-named smart constructor (`newSpscQueue`, `newMpmcQueue`,
`newUnboundedMpmcQueue`, …).

### Bounded SPSC

```nim
import options
import lockfreequeues

# Bounded single-producer, single-consumer queue, capacity 16.
# Single-cardinality sides push/pop directly on the queue.
var queue = newSpscQueue[int, 16]()

discard queue.push(42)   # push returns false when the queue is full
discard queue.push(123)

let item = queue.pop()   # Option[int]: some(42)
assert item == some(42)
```

### Unbounded MPMC

The simplest setup — the queue auto-creates a private `DebraManager`. Each
operating thread registers itself by calling `.attach()` on its view before
its first push/pop (registration is thread-affine, so attach on the thread
that will actually push/pop). Multi-cardinality sides operate through views
obtained with `getProducer()` / `getConsumer()`:

```nim
import options
import lockfreequeues

# Unbounded MPMC: segment size 8, registry sized for 4 lifetime threads.
var queue = newUnboundedMpmcQueue[int, stEager, 8, 4]()

var producer = queue.getProducer()
producer.attach()         # on the producer thread, before push
producer.push(42)         # unbounded push never blocks; returns nothing

var consumer = queue.getConsumer()
consumer.attach()         # on the consumer thread, before pop
let item = consumer.pop() # Option[int]: some(42)
assert item == some(42)
```

`MaxThreads` (the `4` above) counts the lifetime number of distinct threads
that will ever operate the queue, not the concurrent count: nim-debra has no
per-thread unregister, so each `attach()` consumes a registry slot for the
manager's lifetime. Size it accordingly. The unbounded SPSC arm
(`newUnboundedSpscQueue`) is debra-free and needs no `attach()`.

### Copy semantics

`BQueue` is **copyable**: it owns only inline slot storage, so a field-wise
copy is sound.

`Queue` is **move-only** (non-copyable): it owns a heap `ptr Segment` chain
and, for the debra-integrated cardinalities, a `ptr DebraManager`. Copying
would alias those owned pointers and double-free / use-after-free when both
copies run `=destroy`, so `=copy` is a compile-time error. Move the `Queue`
(it has move semantics) or share it across threads by `ptr` / `var`
parameter — as the examples below pass `addr queue` into worker threads.

See [`examples/`](examples/) for full multi-threaded examples and patterns
(audio buffer, job scheduler, event collector, task fan-out).

## Choosing a queue

### Bounded queues

All bounded queues are the `BQueue` generic, built with a family-named
smart constructor.

| Topology | Constructor       | Producers | Consumers | Push      | Pop       |
|----------|-------------------|-----------|-----------|-----------|-----------|
| SPSC     | `newSpscQueue`  | 1         | 1         | wait-free | wait-free |
| SPMC     | `newSpmcQueue`  | 1         | many      | wait-free | lock-free |
| MPSC     | `newMpscQueue`  | many      | 1         | lock-free | wait-free |
| MPMC     | `newMpmcQueue`  | many      | many      | lock-free | lock-free |

Bounded queues are ring buffers with compile-time capacity. None require a `DebraManager` or per-thread handles.

### Unbounded queues

All unbounded queues are the `Queue` generic, built with a family-named
smart constructor.

| Topology | Constructor               | Producers | Consumers | Push      | Pop       | `DebraManager` | Per-thread handle |
|----------|---------------------------|-----------|-----------|-----------|-----------|----------------|-------------------|
| SPSC     | `newUnboundedSpscQueue` | 1         | 1         | wait-free | wait-free | not needed     | not needed        |
| SPMC     | `newUnboundedSpmcQueue` | 1         | many      | wait-free | lock-free | required       | consumer side     |
| MPSC     | `newUnboundedMpscQueue` | many      | 1         | lock-free | wait-free | required       | producer side     |
| MPMC     | `newUnboundedMpmcQueue` | many      | many      | lock-free | lock-free | required       | both              |

The unbounded SPSC queue is special: with one producer and one consumer the consumer is the only thread freeing segments, so it does not need DEBRA. Every other unbounded variant does, because multiple threads can race to detach a segment.

### Bounded vs unbounded

Bounded queues are ring buffers with compile-time capacity. Use them when:

- memory usage must be predictable;
- you are working in embedded or real-time systems;
- producer and consumer counts are known at compile time.

Unbounded queues are linked segments that grow as needed. Use them when:

- workload is bursty or unpredictable;
- producer or consumer threads are created dynamically;
- some memory growth is acceptable in exchange for never blocking on a full queue.

## Dependencies

- [`debra`](https://github.com/elijahr/nim-debra) `>= 0.8.0` for epoch-based
  reclamation in the unbounded multi-thread queues. `nim-debra` is a
  general-purpose DEBRA+ implementation; nothing about it is specific to this
  library, and it can be reused as the reclamation backend for any lock-free
  data structure you build.
- [`typestates`](https://github.com/elijahr/nim-typestates) `>= 0.10.0` for the
  slot-ownership state machines that back push and pop.

## Compile-time options

| Flag                                       | Default | Effect                                                                                  |
|--------------------------------------------|---------|-----------------------------------------------------------------------------------------|
| `-d:allowNonLockFreeQueueItems`            | off     | Disable the arc/orc compile-time check that rejects `ref` item types.                   |
| `-d:nimEnforceLockFreeAtomics`             | off     | Nim flag; fail compilation if any atomic operation falls back to spinlocks.             |
| `-d:LockFreeQueuesAdvanceEvery=N`          | 64      | DEBRA epoch-advance cadence for unbounded queues' Eager reclamation per-pop fast path.  |

## Thread safety

By design, `lockfreequeues` rejects queues whose item type is `ref T` under arc, orc, or atomicArc. This is intentional: a queue holding `ref` items is not safe under our concurrency model.

Slots are stored in a plain `array[S, T]` and shared across threads. When a producer writes `seg.data[i] = item` and a consumer reads `seg.data[i]`, those assignments fire Nim's `=copy`/`=sink` hooks for ref types, which mutate the refcount on the same object that other threads are reading or writing concurrently. That race exists regardless of whether the underlying refcount itself is atomic — arc's refcount is non-atomic, and even orc/atomicArc's atomic refcount can't make a torn read/write of the slot value safe.

Use a value type, a `ptr T`, or, if you accept the trade-off, compile with `-d:allowNonLockFreeQueueItems` to disable the check.

The full safety model — slot-ownership typestates, why the queue itself is lock-free even when items are not, and the matrix of MM x sanitiser combinations under CI — lives in [`docs/guide/safety-model.md`](docs/guide/safety-model.md). The typestate transitions are documented in [`docs/guide/slot-ownership-typestates.md`](docs/guide/slot-ownership-typestates.md).

## Benchmarks

The numbers below are a hand-curated summary of the four bounded
lockfreequeues variants on `ubuntu-latest` (4 vCPU, x86_64) at one
representative shape each. They are updated at release prep, NOT on
every devel push, and may lag the live data by up to one release
cycle. The "always-fresh" view lives at the chart page below.

<!-- BENCHMARKS:start -->
**Headline:** `Mpmc` (MPMC, bounded) sustains **18,209 ops/ms at 4p4c** on
`ubuntu-latest`, against **1,723 ops/ms** for Nim's stdlib `Channel` at the
same shape — about **10.6x** faster under heavy multi-producer multi-consumer
contention.

| Variant  | Topology | Shape | Throughput (ops/ms) | vs `system/Channel` (same shape) |
|----------|----------|-------|--------------------:|----------------------------------|
| `Spsc` | SPSC     | 1p1c  |               7,592 | — (no SPSC `Channel` adapter)    |
| `Spmc` | SPMC     | 1p2c  |              22,399 | — (no SPMC `Channel` adapter)    |
| `Mpsc` | MPSC     | 4p1c  |              13,667 | 3.7x (3,667 ops/ms)              |
| `Mpmc` | MPMC     | 4p4c  |              18,209 | 10.6x (1,723 ops/ms)             |

Numbers are pulled from `docs/assets/bench-results/example.json`, the
checked-in `ubuntu-latest` snapshot used as the chart's offline fallback.
Live updating chart: <https://elijahr.github.io/lockfreequeues/latest/benchmarks/>.
<!-- BENCHMARKS:end -->

See [`benchmarks/`](benchmarks/) for the full suite, methodology, the
hand-curation procedure, and adapter implementations.

## Examples

Examples are in [`examples/`](examples/) and can be run with:

```sh
nimble examples
```

## Running tests

```sh
nimble test
```

CI (see [`.github/workflows/build.yml`](.github/workflows/build.yml)) runs the
suite on:

- Runners: `ubuntu-24.04` (x86_64), `ubuntu-24.04-arm` (native arm64),
  `macos-latest` (arm64).
- Memory managers: `arc`, `orc`, `refc`, `atomicArc`.
- Backends: C and C++.
- Sanitisers: ThreadSanitizer (TSAN) on `atomicArc`, AddressSanitizer (ASAN).
- Lock-free atomic enforcement: `-d:nimEnforceLockFreeAtomics` lane on `arc`
  and `orc`.

192 tests across the bounded, unbounded, threaded, and lock-free-check suites.

## Contributing

Pull requests and issues welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). The current release is
[5.0.0](CHANGELOG.md#500---2026-05-25).

## References

- Juho Snellman, ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/)
  ([alt](https://web.archive.org/web/20200530040210/https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/)).
- Mamy Ratsimbazafy, [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature)
  for weave.
- Henrique F. Bucher, ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370)
  ([alt](https://web.archive.org/web/20191225164231/http://www.vitorian.com/x1/archives/370)).
- Maged M. Michael and Michael L. Scott, "Simple, Fast, and Practical
  Non-Blocking and Blocking Concurrent Queue Algorithms" (PODC 1996).
- Dmitry Vyukov's writings on bounded MPMC ring buffers and CAS-based
  coordination patterns.
- Trevor Brown, ["Reclaiming Memory for Lock-Free Data Structures: There has to
  be a Better Way"](https://www.cs.utoronto.ca/~tabrown/debra/) (DEBRA, the
  reclamation scheme used by the unbounded queues).

Many thanks to Mamy Ratsimbazafy for reviewing the initial release and
offering suggestions.

## License

MIT — see [LICENSE](LICENSE).
