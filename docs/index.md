# lockfreequeues

Lock-free queues for Nim, implemented as ring buffers (bounded) and linked segments (unbounded).

## Overview

v5 exposes two unified, cardinality-parameterized queue types —
[`BQueue`](api/bqueue.md) (bounded) and [`Queue`](api/queue.md)
(unbounded). Each covers all four producer/consumer combinations,
selected at compile time via the `ccProd` / `ccCons` parameters.

### Bounded `BQueue` (Fixed Capacity)

Ring buffer with compile-time capacity. Best for predictable memory usage and embedded systems. [`BQueue`](api/bqueue.md) covers:

| Cardinality | Producers | Consumers | Push | Pop |
|-------------|-----------|-----------|------|-----|
| SPSC | Single | Single | Wait-free | Wait-free |
| SPMC | Single | Multiple | Wait-free | Lock-free |
| MPSC | Multiple | Single | Lock-free | Wait-free |
| MPMC | Multiple | Multiple | Lock-free | Lock-free |

### Unbounded `Queue` (Dynamic Capacity)

Linked segments that grow as needed. The MP/MC shapes use DEBRA+ epoch-based reclamation (via [nim-debra](https://github.com/elijahr/nim-debra)) for safe memory deallocation; the SPSC shape frees retired segments inline (no manager). [`Queue`](api/queue.md) covers:

| Cardinality | Producers | Consumers | Push | Pop |
|-------------|-----------|-----------|------|-----|
| SPSC | Single | Single | Wait-free | Wait-free |
| SPMC | Single | Multiple | Wait-free | Lock-free |
| MPSC | Multiple | Single | Lock-free | Wait-free |
| MPMC | Multiple | Multiple | Lock-free | Lock-free |

## Compatibility

| Requirement | Supported |
|-------------|-----------|
| Nim         | `>= 2.2.0` |
| Memory managers | `orc` (default), `arc`, `refc`, `atomicArc` |
| Backends    | C, C++ |
| Threads     | `--threads:on` required (default in Nim 2.2+) |
| Platforms (CI-verified) | Linux x86_64, Linux arm64, macOS arm64 |
| Sanitisers (CI-verified) | ThreadSanitizer (under `atomicArc`), AddressSanitizer |
| Dependencies | [`debra`](https://github.com/elijahr/nim-debra) `>= 0.8.0`, [`typestates`](https://github.com/elijahr/nim-typestates) `>= 0.10.0` |
| License     | MIT |

**Item-type constraints.** Slots are shared across threads and stored in a
plain `array[S, T]`, so the queue rejects `ref T` item types under `arc` /
`orc` / `atomicArc` at compile time. Use a value type, a `ptr T`, or pass
`-d:allowNonLockFreeQueueItems` to disable the check at your own risk.

**Atomics.** All atomics route through `debra/atomics`, which statically
rejects any `Atomic[T]` instantiation that would fall back to libatomic
spinlocks. Enforcement is on by default; opt out with
`-d:debraAllowNonLockFreeAtomics` (per-call-site warning fires).

## Installation

```sh
nimble install lockfreequeues
```

## Quick Start

### Bounded Queue

```nim
import lockfreequeues

# Single-producer, single-consumer bounded queue with capacity 16.
var queue = newSpscQueue[int, 16]()

discard queue.push(42)
discard queue.push(123)

let item = queue.pop()  # some(42)
```

### Unbounded Queue (single-producer, single-consumer)

The SPSC `Queue` shape does not need DEBRA reclamation: the producer and
consumer each hold their own segment pointer and the consumer-side advance is
the only freer.

```nim
import lockfreequeues

# Unbounded SPSC queue with segment size 64.
var queue = newQueue(Queue[int, ccSingle, ccSingle, stEager, 64, 1])

var p = queue.getProducer()
p.push(42)              # never fails — grows as needed
let item = queue.pop()  # some(42)
```

### Unbounded Queue (multi-producer, multi-consumer)

The MP/MC unbounded shapes use a `DebraManager` for safe segment
reclamation. The auto-create constructor heap-allocates a private manager;
each operating thread then `attach()`es its view on the thread that will
push/pop through it (DEBRA registration is thread-affine):

```nim
import lockfreequeues

# Auto-create MPMC: segment size 64, registry capacity 4.
var queue = newQueue(Queue[int, ccMulti, ccMulti, stEager, 64, 4])

var producer = queue.getProducer()
producer.attach()  # registers this thread; may raise DebraRegistrationError
producer.push(42)

var consumer = queue.getConsumer()
consumer.attach()
let item = consumer.pop()  # some(42)
```

## Choosing a Queue

**Use bounded queues when:**

- Memory usage must be predictable
- Working in embedded or real-time systems
- Producer/consumer counts are known at compile time

**Use unbounded queues when:**

- Workload is bursty or unpredictable
- Producer/consumer threads are created dynamically
- Memory growth is acceptable

## Examples

Examples are in the [examples](https://github.com/elijahr/lockfreequeues/tree/devel/examples) directory:

```sh
nimble examples
```

## References

- Juho Snellman, ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/).
- Mamy Ratsimbazafy, [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature) for weave.
- Henrique F. Bucher, ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370).
- Maged M. Michael and Michael L. Scott, "Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms" (PODC 1996) — the lock-free linked-list queue that the unbounded segment chain generalises.
- Dmitry Vyukov's writings on bounded MPMC ring buffers and CAS-based coordination patterns — the per-slot sequence counter protocol used by the bounded multi-cardinality variants.
- Trevor Brown, ["Reclaiming Memory for Lock-Free Data Structures: There has to be a Better Way"](https://www.cs.utoronto.ca/~tabrown/debra/) (DEBRA, the epoch-based reclamation scheme used by the unbounded multi-cardinality queues via [nim-debra](https://github.com/elijahr/nim-debra)).
