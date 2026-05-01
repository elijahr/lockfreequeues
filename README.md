[![build](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml/badge.svg)](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml)

# lockfreequeues

Lock-free queues for Nim. Bounded queues are ring buffers; unbounded queues are
linked segments reclaimed via [DEBRA](https://github.com/elijahr/nim-debra).
All variants cover SPSC, SPMC, MPSC, and MPMC.

API documentation: <https://elijahr.github.io/lockfreequeues>

## Why this library

If two threads need to hand items to each other and you cannot afford a mutex,
the answer is a lock-free queue. Picking the right one is the hard part: do you
have one producer or many, one consumer or many, a fixed capacity or not? Each
choice changes the algorithm and the cost. `lockfreequeues` ships eight queues
covering every cell of that grid, with a uniform API and verified ordering
guarantees.

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

### Bounded SPSC

```nim
import options
import lockfreequeues

# Bounded single-producer, single-consumer queue, capacity 16
var queue = initSipsic[16, int]()

discard queue.push(42)
discard queue.push(123)

let item = queue.pop()  # some(42)
assert item == some(42)
```

### Unbounded MPMC

The simplest setup — the queue auto-creates a private `DebraManager` and
threads auto-register on first `getProducer()` / `getConsumer()` call:

```nim
import options
import lockfreequeues

var queue = newUnboundedMupmuc[64, int, 4]()

var producer = queue.getProducer()
var consumer = queue.getConsumer()

producer.push(42)
let item = consumer.pop()  # some(42)
assert item == some(42)
```

For multi-queue setups that share a manager, pass it explicitly. Threads
that touch multiple queues should also share a single `ThreadHandle` to
avoid burning a slot per queue:

```nim
import options
import debra
import lockfreequeues

var manager = initDebraManager[4]()
var queueA = newUnboundedMupmuc[64, int, 4](addr manager)
var queueB = newUnboundedMupmuc[64, int, 4](addr manager)

let handle = manager.registerThread()
var producer = queueA.getProducer(handle)
var consumer = queueB.getConsumer(handle)

producer.push(42)
let item = consumer.pop()
```

See [`examples/`](examples/) for full multi-threaded examples and patterns
(audio buffer, job scheduler, event collector, task fan-out).

## Choosing a queue

### Bounded queues

| Queue    | Producers | Consumers | Push      | Pop       |
|----------|-----------|-----------|-----------|-----------|
| `Sipsic` | 1         | 1         | wait-free | wait-free |
| `Sipmuc` | 1         | many      | wait-free | lock-free |
| `Mupsic` | many      | 1         | lock-free | wait-free |
| `Mupmuc` | many      | many      | lock-free | lock-free |

Bounded queues are ring buffers with compile-time capacity. None require a `DebraManager` or per-thread handles.

### Unbounded queues

| Queue              | Producers | Consumers | Push      | Pop       | `DebraManager` | Per-thread handle |
|--------------------|-----------|-----------|-----------|-----------|----------------|-------------------|
| `UnboundedSipsic`  | 1         | 1         | wait-free | wait-free | not needed     | not needed        |
| `UnboundedSipmuc`  | 1         | many      | wait-free | lock-free | required       | consumer side     |
| `UnboundedMupsic`  | many      | 1         | lock-free | wait-free | required       | producer side     |
| `UnboundedMupmuc`  | many      | many      | lock-free | lock-free | required       | both              |

`UnboundedSipsic` is special: with one producer and one consumer the consumer is the only thread freeing segments, so it does not need DEBRA. Every other unbounded variant does, because multiple threads can race to detach a segment.

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

- [`debra`](https://github.com/elijahr/nim-debra) `>= 0.3.0` for epoch-based
  reclamation in the unbounded multi-thread queues. `nim-debra` is a
  general-purpose DEBRA+ implementation; nothing about it is specific to this
  library, and it can be reused as the reclamation backend for any lock-free
  data structure you build.
- [`typestates`](https://github.com/elijahr/nim-typestates) `>= 0.3.1` for the
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

The full safety model — slot-ownership typestates, why the queue itself is lock-free even when items are not, and the matrix of MM x sanitiser combinations under CI — lives in [`docs/safety-model.md`](docs/safety-model.md). The typestate transitions are documented in [`docs/slot-ownership-typestates.md`](docs/slot-ownership-typestates.md).

## Benchmarks

Throughput and latency results are checked into
[`benchmarks/results/latest.json`](benchmarks/results/latest.json) and rendered
into the table below. Re-run the suite with `nimble benchmarks`, then update
this section with `nim r benchmarks/render_readme.nim`.

<!-- BENCHMARKS:start -->
_Platform: macosx arm64, 8 cores, 2025-12-03T22:24:55Z._

| implementation | threads | throughput (ops/ms) | p50 latency (ns) |
|----------------|---------|---------------------|------------------|
| `lockfreequeues/Sipsic` | 1P/1C | 7411.0 | 292 |
| `nim/channels` | 1P/1C | 1199.7 | — |
| `nim/channels` | 2P/2C | 815.8 | — |
| `nim/channels` | 4P/4C | 1779.5 | — |

_Numbers regenerated by `nim r benchmarks/render_readme.nim` from `benchmarks/results/latest.json`._

<!-- BENCHMARKS:end -->

See [`benchmarks/`](benchmarks/) for the full suite, methodology, and
adapter implementations.

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
[3.2.0](CHANGELOG.md#320---2026-04-27).

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
