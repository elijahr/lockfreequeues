# Queue

`Queue[T, ccProd, ccCons, ST, S, MaxThreads]` is the unified unbounded,
lock-free queue. A single generic type covers all four
producer/consumer cardinality combinations — SPSC, MPSC, SPMC, and
MPMC — selected at compile time through `ccProd` and `ccCons`. It
replaces the v4.x family-prefixed unbounded types (`UnboundedSipsic`,
`UnboundedSipmuc`, `UnboundedMupsic`, `UnboundedMupmuc`).

## Overview

- **Capacity**: Dynamic — grows by linking fixed-size segments
  (`S` items per segment). Push never fails for capacity reasons.
- **Push**: Wait-free (SPSC) or lock-free (multi-producer)
- **Pop**: Wait-free (SPSC) or lock-free (multi-consumer)

Body layout splits on `(ccProd, ccCons) is (ccSingle, ccSingle)`:

- **SPSC** (`ccSingle × ccSingle`): no memory-reclamation manager. The
  linked-segment, committed-flag-free SPSC protocol (formerly the
  standalone `UnboundedSipsic` type) is absorbed verbatim; retired
  segments are freed inline by the consumer-side advance.
- **MPSC / SPMC / MPMC**: DEBRA+ epoch-based memory reclamation via
  [nim-debra](https://github.com/elijahr/nim-debra). The queue owns or
  borrows a `DebraManager`, and each operating thread holds a
  per-thread handle for the pin/retire cycle.

## Type Parameters

- `T` — Item type
- `ccProd: static PinScopeCardinality` — Producer cardinality
  (`ccSingle` or `ccMulti`)
- `ccCons: static PinScopeCardinality` — Consumer cardinality
  (`ccSingle` or `ccMulti`)
- `ST: static DeallocationStrategy` — Reclamation policy (`stManual`
  or `stEager`). Inert for the debra-free SPSC shape.
- `S: static int` — Segment size in items (must be `> 0`; power of 2,
  multiple of the cache line, recommended)
- `MaxThreads: static int` — DEBRA thread-registry capacity (must be
  `> 0`). A type-uniform phantom on the SPSC shape, which consumes no
  registry slots.

The parameter order is load-bearing: `T, ccProd, ccCons, ST, S, MaxThreads`.

## Constructors

`newQueue(Queue[T, ccProd, ccCons, ST, S, MaxThreads])` is the
canonical generic smart constructor. The typedesc-only overload
auto-creates a private `DebraManager` (and sets `ownsManager = true`)
for the reclaiming shapes, or skips manager allocation entirely for the
SPSC shape. Manager-borrowed overloads accept an existing
`DebraManager` (and optionally a `ThreadHandle`) and set
`ownsManager = false`.

Family-named thin wrappers are retained for ergonomic continuity with
the v3.x/v4.x naming; all compile to the same `Queue` type:

- `newUnboundedSipsicQueue` — `ccSingle × ccSingle` (SPSC)
- `newUnboundedMupsicQueue` — `ccMulti × ccSingle` (MPSC)
- `newUnboundedSipmucQueue` — `ccSingle × ccMulti` (SPMC)
- `newUnboundedMupmucQueue` — `ccMulti × ccMulti` (MPMC)

## Attach-Time Thread Registration

DEBRA thread registration is **thread-affine**: it stamps the calling
thread and installs a signal handler on that OS thread. Registering on
the wrong thread mis-routes the handle. Therefore, for the reclaiming
shapes:

- **No thread is registered at construction.**
- `getProducer()` / `getConsumer()` return an **unregistered** view:
  the calling thread reserves an index but does not register.
- Each operating thread calls `attach()` on its view **on the thread
  that will subsequently `push()` / `pop()` through it**. `attach()`
  performs the debra registration and may raise
  `DebraRegistrationError`.

This differs from pre-v5.0.0, where `get*()` registered at get-time.

## Usage

```nim
import lockfreequeues

# SPSC: debra-free; no manager, no attach needed.
var spsc = newQueue(Queue[int, ccSingle, ccSingle, stEager, 64, 1])
var spscProducer = spsc.getProducer()
spscProducer.push(42)              # never fails — grows as needed
let a = spsc.pop()                 # some(42)

# MPMC: each operating thread attaches before its first push/pop.
var mpmc = newQueue(Queue[int, ccMulti, ccMulti, stEager, 64, 8])
var producer = mpmc.getProducer()
producer.attach()                  # registers this thread (may raise
                                   #   DebraRegistrationError)
producer.push(99)
var consumer = mpmc.getConsumer()
consumer.attach()
let b = consumer.pop()             # some(99)
```

## Calling Convention by Cardinality

As with `BQueue`, the single side of each axis operates directly on the
queue; the multi side requires a per-thread handle from
`getProducer()` / `getConsumer()`. Direct `push` on a multi-producer
`Queue` (or `pop` on a multi-consumer `Queue`) is a **compile-time
error** whose diagnostic names only the user-visible `QueueProducer` /
`QueueConsumer` aliases.

## Typestate Notes

`Queue` carries a Lifecycle typestate (`QueueInit -> QueueDestroyed`)
driven by `=destroy`; the `QueueProducer` / `QueueConsumer` views carry
a Claim-state typestate (`QCUnclaimed -> QCBothClaimed`). All
push/pop/attach/detach operations are state-preserving; only the
destructor moves a value to its terminal state. Use-after-destroy is a
documented limitation; see the CHANGELOG `[5.0.0]` entry.

## See also

- [Memory Management](../guide/memory-management.md) — DEBRA managers,
  deallocation strategies, and the attach/detach lifecycle.
- [Safety Model](../guide/safety-model.md) — happens-before guarantees.
- [Bounded vs Unbounded](../guide/bounded-vs-unbounded.md) — choosing
  between `Queue` and `BQueue`.

::: lockfreequeues/queue
