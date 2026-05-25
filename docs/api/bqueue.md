# BQueue

`BQueue[T, ccProd, ccCons, N, P, C]` is the unified bounded, lock-free
queue. A single generic type covers all four producer/consumer
cardinality combinations — SPSC, MPSC, SPMC, and MPMC — selected at
compile time through the `ccProd` and `ccCons` parameters. It replaces
the v4.x family-prefixed bounded types (`Sipsic`, `Sipmuc`, `Mupsic`,
`Mupmuc`).

## Overview

- **Capacity**: Fixed at compile time (`N`)
- **Push**: Wait-free (SPSC) or lock-free (multi-producer)
- **Pop**: Wait-free (SPSC) or lock-free (multi-consumer)
- **No heap state**: the bounded body owns no dynamic memory and needs
  no memory-reclamation manager. The default destructor is sufficient.

`BQueue` carries no debra integration and none of the unbounded
`Queue`'s `ST` / `S` / `MaxThreads` axes. Internally it dispatches on
`(ccProd, ccCons)`: the SPSC shape uses an `N+1`-slot ring with plain
`Atomic[int]` head/tail; every multi-cardinality shape uses a Vyukov
per-slot `seq`-counter cell array with `Atomic[uint64]` head/tail. The
sequence-counter protocol carries the producer→consumer and
consumer→next-producer happens-before edges without a separate
`committed` flag array.

## Type Parameters

- `T` — Item type
- `ccProd: static PinScopeCardinality` — Producer cardinality
  (`ccSingle` or `ccMulti`)
- `ccCons: static PinScopeCardinality` — Consumer cardinality
  (`ccSingle` or `ccMulti`)
- `N: static int` — Queue capacity (must be `> 0`; power of 2
  recommended)
- `P: static int` — Producer-registry capacity. Required `> 0` when
  `ccProd == ccMulti`; must be `0` when `ccProd == ccSingle`.
- `C: static int` — Consumer-registry capacity. Required `> 0` when
  `ccCons == ccMulti`; must be `0` when `ccCons == ccSingle`.

The parameter order is load-bearing: `T, ccProd, ccCons, N, P, C`.

## Constructors

`newBQueue[T, ccProd, ccCons, N, P, C]()` is the canonical generic
smart constructor. Family-named thin wrappers are retained for
ergonomic continuity with the v3.x/v4.x naming and to minimize churn
in downstream call sites; all compile to the same `BQueue` type:

- `newSipsicQueue[T, N]()` — `ccSingle × ccSingle` (SPSC)
- `newMupsicQueue[T, N, P]()` — `ccMulti × ccSingle` (MPSC)
- `newSipmucQueue[T, N, C]()` — `ccSingle × ccMulti` (SPMC)
- `newMupmucQueue[T, N, P, C]()` — `ccMulti × ccMulti` (MPMC)

## Usage

```nim
import lockfreequeues

# SPSC: single producer, single consumer, capacity 16.
# No handles needed — push/pop go directly on the queue.
var spsc = newBQueue[int, ccSingle, ccSingle, N = 16, P = 0, C = 0]()
discard spsc.push(42)
let a = spsc.pop()                 # some(42)

# MPMC: capacity 64, up to 4 producers and 4 consumers.
var mpmc = newBQueue[int, ccMulti, ccMulti, N = 64, P = 4, C = 4]()
var producer = mpmc.getProducer()
discard producer.push(99)
var consumer = mpmc.getConsumer()
let b = consumer.pop()             # some(99)
```

## Calling Convention by Cardinality

The single side of each axis operates directly on the queue; the multi
side requires a per-thread handle obtained from `getProducer()` /
`getConsumer()`:

| Shape | Push | Pop |
|-------|------|-----|
| SPSC | `queue.push(item)` | `queue.pop()` |
| MPSC | `producer.push(item)` | `queue.pop()` |
| SPMC | `queue.push(item)` | `consumer.pop()` |
| MPMC | `producer.push(item)` | `consumer.pop()` |

Calling `push` directly on a multi-producer `BQueue` (or `pop` on a
multi-consumer `BQueue`) is a **compile-time error** — a `{.error.}`
overload directs the caller to `BQueue.getProducer().push(item)` /
`BQueue.getConsumer().pop()`. The diagnostic names only the
user-visible `BQueueProducer` / `BQueueConsumer` aliases.

When all `P` producer slots are taken, `getProducer()` raises
`NoProducersAvailableError`; when all `C` consumer slots are taken,
`getConsumer()` raises `NoConsumersAvailableError`.

## Typestate Notes

`BQueue` carries a Lifecycle typestate (`BQueueInit -> BQueueDestroyed`)
driven by `=destroy`; the per-thread `BQueueProducer` / `BQueueConsumer`
views carry a Claim-state typestate (`Unclaimed -> BothClaimed`). All
push/pop/attach/detach operations are state-preserving and emit no
static transition; only the destructor moves a value to its terminal
state. Use-after-destroy is a documented limitation (typestates does
not statically catch a method call on an already-destroyed value); see
the CHANGELOG `[5.0.0]` entry for details.

## See also

- [Safety Model](../guide/safety-model.md) — happens-before guarantees
  and the Vyukov per-slot `seq` protocol.
- [Slot Ownership Typestates](../guide/slot-ownership-typestates.md) —
  the shared internal state machine across all bounded shapes.
- [Bounded vs Unbounded](../guide/bounded-vs-unbounded.md) — choosing
  between `BQueue` and `Queue`.

::: lockfreequeues/bqueue
