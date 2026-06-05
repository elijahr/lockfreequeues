# Queue

!!! warning "v5.0.0 — Static Thread-Affinity Endpoint API"

    v5.0.0 is a hard-break release. The v4.x `Bound[T, Tag, BQueue[...]]` endpoint /
    `Bound[T, Tag, Queue[...]]` endpoint / `attach()` / `bindConsumer()` API is REMOVED;
    replaced by the `Unbound → Bound → Closed` endpoint lifecycle.
    See [`docs/migrations/v5.0.0.md`](../migrations/v5.0.0.md) for the
    full migration guide + v4.x → v5.0.0 cookbook + breaking-change
    checklist.


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
  standalone `UnboundedSpsc` type) is absorbed verbatim; retired
  segments are freed inline by the consumer-side advance.
- **MPSC / SPMC / MPMC**: DEBRA+ epoch-based memory reclamation
  ([Brown 2015](https://www.cs.utoronto.ca/~tabrown/debra/)) via
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

!!! warning "v5.0.0 Phase B — unbounded MPMC `T` constraint"

    The unbounded MPMC shape (`Queue[T, ccMulti, ccMulti, …]`) requires
    **`supportsCopyMem(T) AND sizeof(T) <= 8`** (8 bytes on 64-bit;
    4 bytes on 32-bit). Each cell packs a `(seq, payload)` pair into
    a single DWCAS word per the LCRQ paper §4 close-CAS-on-empty
    progress rule.

    Violations fail at compile time with a `{.error.}` overload that
    cites the migration path. For wider or move-only `T`, switch to
    `BQueue[T, ccMulti, ccMulti, …]` (bounded MPMC, Vyukov per-slot
    seq) — `BQueue` preserves general `T` support and is unchanged in
    v5.0.0. To keep unbounded MPMC, wrap as `ptr T`; see
    [`docs/migrations/v5.0.0.md`](../migrations/v5.0.0.md) "Phase B"
    recipes and `examples/job_scheduler.nim`. The other three
    unbounded shapes (SPSC / SPMC / MPSC) are unaffected.

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

- `newUnboundedSpscQueue` — `ccSingle × ccSingle` (SPSC)
- `newUnboundedMpscQueue` — `ccMulti × ccSingle` (MPSC)
- `newUnboundedSpmcQueue` — `ccSingle × ccMulti` (SPMC)
- `newUnboundedMpmcQueue` — `ccMulti × ccMulti` (MPMC)

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
discard producer.bindToThread()  # v5.0.0: replaces v4.x attach()                  # registers this thread (may raise
                                   #   DebraRegistrationError)
producer.push(99)
var consumer = mpmc.getConsumer()
discard consumer.bindToThread()  # v5.0.0: replaces v4.x attach()
let b = consumer.pop()             # some(99)

# MPMC: when the calling thread is also the operating thread,
# `getProducerHere` / `getConsumerHere` are sugar for getX() + attach().
# Prefer this same-thread form; use the explicit getX() + attach()
# pair above when the view is handed off to a worker thread that does
# the push/pop (the attach() must run on that worker thread).
var mpmc2 = newQueue(Queue[int, ccMulti, ccMulti, stEager, 64, 8])
var producer2 = mpmc2.getProducerHere()  # registers on current thread
producer2.push(99)
var consumer2 = mpmc2.getConsumerHere()
let c = consumer2.pop()            # some(99)
```

## Calling Convention by Cardinality

`Queue` always pushes through a `Bound[T, Tag, Queue[...]]` endpoint view — even for
`ccProd == ccSingle`. The view is obtained from `queue.getProducer()`,
and the single-producer arm doesn't require `.bindToThread()`. Pop is
asymmetric: `ccCons == ccSingle` arms expose a bare `queue.pop()`,
while `ccCons == ccMulti` requires a `Bound[T, Tag, Queue[...]]` endpoint view from
`getConsumer()` and per-thread `.bindToThread()`. Direct `push` on a
`Queue` or direct `pop` on a multi-consumer `Queue` is a
**compile-time error** whose diagnostic names only the user-visible
`Bound[T, Tag, Queue[...]]` endpoint / `Bound[T, Tag, Queue[...]]` endpoint aliases.

For the common same-thread case (the calling thread is also the
thread that will push/pop through the returned view),
`getProducerHere()` / `getConsumerHere()` are templates that combine
`getX()` + `attach()` in one call. They are pure sugar: identical
runtime behavior, identical diagnostics. Use the explicit
`getX()` + `attach()` pair when the view is handed off to a worker
thread that does the push/pop, so the `attach()` registers the
correct thread.

## Typestate Notes

`Queue` carries a Lifecycle typestate (`QueueInit -> QueueDestroyed`)
driven by `=destroy`; the `Bound[T, Tag, Queue[...]]` endpoint / `Bound[T, Tag, Queue[...]]` endpoint views carry
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
