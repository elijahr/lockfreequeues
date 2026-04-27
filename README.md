[![build](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml/badge.svg)](https://github.com/elijahr/lockfreequeues/actions/workflows/build.yml)

# lockfreequeues

Concurrent queues for Nim that hold up under arc/orc, with bounded ring buffers
for predictable workloads and unbounded linked-segment queues with epoch-based
reclamation for bursty ones.

Nim's built-in `Channel` works for many programs, but once you start handing
data between threads at high rates, or you need wait-free progress on the hot
path, channels stop being a good fit. lockfreequeues provides eight concrete
queues, one per producer-consumer combination and bounded/unbounded axis, so
you pick the cheapest queue your topology allows instead of paying for
generality you don't need.

Status: **3.2.0 (April 2026)**. Requires Nim 2.2+.

## Installation

```sh
nimble install lockfreequeues
```

That brings in the [nim-debra](https://github.com/elijahr/nim-debra) and
[nim-typestates](https://github.com/elijahr/nim-typestates) dependencies
automatically.

### Dependencies

- `nim >= 2.2.0`
- [`debra >= 0.3.0`](https://github.com/elijahr/nim-debra) — DEBRA+ epoch-based
  memory reclamation. The unbounded queues use it to free retired segments
  safely. nim-debra is a standalone library; you can take it to your own
  project when you're writing other lock-free data structures.
- [`typestates >= 0.3.1`](https://github.com/elijahr/nim-typestates) —
  compile-time state tracking used internally for slot-ownership transitions.

## Picking a queue

The queue family is named for its producer/consumer count: `Sipsic` is
**Si**ngle-**P**roducer **Si**ngle-**C**onsumer, `Mupmuc` is
**Mu**lti-**P**roducer **Mu**lti-**C**onsumer, and so on. Bounded queues use a
fixed-capacity ring buffer; unbounded queues link new segments on as needed
and reclaim them once no thread can still observe the old memory.

A quick word on the progress columns. **Wait-free** means every operation
finishes in a bounded number of its own steps regardless of what other threads
do. **Lock-free** is weaker: the system as a whole always makes progress, but
an individual thread can be starved by contention. Both avoid mutexes; neither
will deadlock. Wait-free is what you want on a real-time audio thread or any
hot path where worst-case latency matters.

| Queue                | Producers | Consumers | Push       | Pop        | Bounded? | Needs `DebraManager`? | Per-thread handle? |
|----------------------|-----------|-----------|------------|------------|----------|-----------------------|---------------------|
| `Sipsic`             | 1         | 1         | wait-free  | wait-free  | yes      | no                    | no                  |
| `Sipmuc`             | 1         | many      | wait-free  | lock-free  | yes      | no                    | per consumer        |
| `Mupsic`             | many      | 1         | lock-free  | wait-free  | yes      | no                    | per producer        |
| `Mupmuc`             | many      | many      | lock-free  | lock-free  | yes      | no                    | both sides          |
| `UnboundedSipsic`    | 1         | 1         | wait-free  | wait-free  | no       | no                    | no                  |
| `UnboundedSipmuc`    | 1         | many      | wait-free  | lock-free  | no       | yes                   | per consumer        |
| `UnboundedMupsic`    | many      | 1         | lock-free  | wait-free  | no       | yes                   | per producer + consumer |
| `UnboundedMupmuc`    | many      | many      | lock-free  | lock-free  | no       | yes                   | both sides          |

Bounded queues are the right default when you can size the worst-case backlog
ahead of time: they allocate once, do no further bookkeeping, and the producer
gets honest backpressure (`push` returns `false` when full). Unbounded queues
trade a little overhead for elasticity. Pushes never fail, the queue grows
under pressure, and DEBRA reclaims segments once every thread that could still
read them has moved on. If your producers can outrun the consumer for a while
and you'd rather buffer than drop, the unbounded variants are designed for
that.

`UnboundedSipsic` is the odd one out: with exactly one reader and one writer
there is nothing to reclaim concurrently, so it doesn't need a `DebraManager`
at all.

## Quick Start

The simplest case is a single producer talking to a single consumer through
a bounded queue. No DEBRA, no per-thread handles, just `push` and `pop`.

```nim
import std/options
import lockfreequeues

# Capacity 16, items are ints. Allocated once, never resized.
var queue = initSipsic[16, int]()

# Producer side. push returns false if the queue is full.
discard queue.push(42)
discard queue.push(123)

# Consumer side. pop returns Option[T]; none when empty.
let item: Option[int] = queue.pop()  # some(42)
let next = queue.pop()                # some(123)
```

When you want elasticity and multiple producers and consumers, switch to
`UnboundedMupmuc`. The pattern is: stand up a `DebraManager`, register every
thread that will touch the queue, and ask the queue for a producer or
consumer handle.

```nim
import std/options
import debra
import lockfreequeues

const MaxThreads = 8  # upper bound on threads that touch the queue

var manager = initDebraManager[MaxThreads]()
var queue = newUnboundedMupmuc[64, int, MaxThreads](addr manager)

# Each thread does this once, before its first push or pop.
let producerHandle = registerThread(manager)
let consumerHandle = registerThread(manager)

var producer = queue.getProducer(producerHandle)
var consumer = queue.getConsumer(consumerHandle)

producer.push(42)              # never blocks, never fails
let item = consumer.pop()      # some(42)
```

The segment size (`64` above) is the unit of allocation. Pick something large
enough that the queue isn't constantly allocating fresh segments under load,
but small enough that retired segments can be reclaimed promptly. 64 is a
reasonable default for most workloads.

There are full worked examples for every queue type in [`examples/`](examples/),
including an audio ring buffer, a fan-out task scheduler, an event collector,
and a job scheduler. Run them with `nimble examples`.

## Lock-free safety in one rule

If you store a `ref` type in any of these queues under arc/orc, compilation
fails. Reference counting on `ref` types can fall back to spinlocks on some
platforms, which silently breaks the lock-free guarantee. Use `int`, `uint64`,
`pointer`, `ptr T`, or plain value objects instead.

If you understand the trade-off and need `ref`, opt in explicitly:

```sh
nim c -d:allowNonLockFreeQueueItems your_program.nim
```

The longer version, including testing patterns and the reasoning behind the
slot-ownership typestate machine, is in
[`docs/slot-ownership-typestates.md`](docs/slot-ownership-typestates.md).

## Compile-time options

- `-d:allowNonLockFreeQueueItems` — permit `ref` item types (see above).
- `-d:nimEnforceLockFreeAtomics` — make the Nim compiler refuse to fall back
  to spinlock-emulated atomics. CI runs the test suite with this flag set so
  regressions show up immediately.
- `-d:LockFreeQueuesAdvanceEvery=N` (default 64) — how often the unbounded
  queues' eager reclamation paths call `advanceEvery` on their DEBRA handle.
  Lower values reclaim more aggressively at the cost of more epoch traffic;
  higher values amortize epoch advancement across more pops at the cost of
  delaying reclamation.

## Benchmarks

<!-- BENCHMARKS:start -->

Numbers regenerated by `nimble benchmarks:readme` from `benchmarks/results/latest.json`. See [`benchmarks/`](benchmarks/) for the full suite.

_Last run: 2025-12-03T22:24:55Z on macosx arm64._

| Implementation | Threads | Throughput (ops/ms) | p50 latency (ns) | p99 latency (ns) |
|---|---|---:|---:|---:|
| `lockfreequeues/Sipsic` | 1P/1C | 7,411 | 292 | 959 |
| `nim/channels` | 1P/1C | 1,200 | n/a | n/a |
| `nim/channels` | 2P/2C | 816 | n/a | n/a |
| `nim/channels` | 4P/4C | 1,780 | n/a | n/a |

<!-- BENCHMARKS:end -->

The benchmark runner lives in [`benchmarks/`](benchmarks/) and compares
lockfreequeues against `nim/channels` and other lock-free libraries. Run the
full suite with `nimble benchmarks`, then regenerate the table above with
`nimble benchmarks:readme`.

## Running tests

```sh
nimble test
```

That runs the suite across both backends (C and C++) and across `arc`, `orc`,
`refc`, and `atomicArc` memory managers. The `arc` and `orc` runs are also
exercised with `-d:nimEnforceLockFreeAtomics` to catch any silent fallback to
spinlock-emulated atomics. By default it also runs the suite under LLVM
ThreadSanitizer and AddressSanitizer; set `SANITIZE_THREADS=no` or
`SANITIZE_ADDRESS=no` to skip those locally.

CI runs the same matrix on three runners:

| Platform                    | Architecture |
|-----------------------------|--------------|
| `ubuntu-latest`             | x86_64       |
| `ubuntu-24.04-arm`          | arm64 (native) |
| `macos-latest`              | arm64        |

Stress tests live in [`stress-tests/`](stress-tests/) and run with
`nimble stresstests` when you want longer concurrent runs.

## Documentation

- API reference: <https://elijahr.github.io/lockfreequeues>
- Slot-ownership typestate model:
  [`docs/slot-ownership-typestates.md`](docs/slot-ownership-typestates.md)
- Benchmarks methodology: [`benchmarks/README.md`](benchmarks/README.md)
- Release history: [`CHANGELOG.md`](CHANGELOG.md)

## Contributing

Pull requests and issues welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for
the workflow and [`CHANGELOG.md`](CHANGELOG.md) for what's landed in each
release.

## References

The implementations build on a small body of prior work:

- Juho Snellman, ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/)
  ([archive](https://web.archive.org/web/20200530040210/https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/))
- Mamy Ratsimbazafy's [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature)
  for the weave runtime.
- Henrique F Bucher, ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370)
  ([archive](https://web.archive.org/web/20191225164231/http://www.vitorian.com/x1/archives/370))
- Maged M. Michael and Michael L. Scott, "Simple, Fast, and Practical Non-Blocking
  and Blocking Concurrent Queue Algorithms" (PODC 1996), the underpinning for
  the Mupmuc design.
- Trevor Brown, "Reclaiming Memory for Lock-Free Data Structures: There Has to
  Be a Better Way" (PODC 2015), the DEBRA paper that nim-debra implements.

Many thanks to Mamy Ratsimbazafy for reviewing the initial release and offering
suggestions, and to everyone who has filed issues against the earlier 2.x and
3.x lines.

## License

MIT — see [LICENSE](LICENSE).
