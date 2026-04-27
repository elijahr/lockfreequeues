# lockfreequeues

Lock-free queues for Nim, implemented as ring buffers (bounded) and linked segments (unbounded).

## Overview

### Bounded Queues (Fixed Capacity)

Ring buffer implementations with compile-time capacity. Best for predictable memory usage and embedded systems.

| Queue | Producers | Consumers | Push | Pop |
|-------|-----------|-----------|------|-----|
| [Sipsic](api/sipsic.md) | Single | Single | Wait-free | Wait-free |
| [Sipmuc](api/sipmuc.md) | Single | Multiple | Wait-free | Lock-free |
| [Mupsic](api/mupsic.md) | Multiple | Single | Lock-free | Wait-free |
| [Mupmuc](api/mupmuc.md) | Multiple | Multiple | Lock-free | Lock-free |

### Unbounded Queues (Dynamic Capacity)

Linked segment implementations that grow as needed. Use epoch-based reclamation for safe memory deallocation.

| Queue | Producers | Consumers | Push | Pop |
|-------|-----------|-----------|------|-----|
| UnboundedSipsic | Single | Single | Wait-free | Wait-free |
| UnboundedSipmuc | Single | Multiple | Wait-free | Lock-free |
| UnboundedMupsic | Multiple | Single | Lock-free | Wait-free |
| UnboundedMupmuc | Multiple | Multiple | Lock-free | Lock-free |

## Installation

```sh
nimble install lockfreequeues
```

## Quick Start

### Bounded Queue

```nim
import lockfreequeues

# Single-producer, single-consumer queue with capacity 16
var queue = initSipsic[16, int]()

queue.push(42)
queue.push(123)

let item = queue.pop()  # some(42)
```

### Unbounded Queue

`UnboundedSipsic` (single producer, single consumer) does not need a
`DebraManager` — with one reader and one writer, no concurrent reclamation
is required.

```nim
import lockfreequeues

# Unbounded SPSC queue with segment size 64.
var queue = newUnboundedSipsic[64, int]()

queue.push(42)            # never fails, grows as needed
let item = queue.pop()    # some(42)
```

The other unbounded queues (`UnboundedSipmuc`, `UnboundedMupsic`,
`UnboundedMupmuc`) need a `DebraManager` and per-thread handles for safe
memory reclamation. See the [README's Quick Start](../README.md#quick-start)
for an `UnboundedMupmuc` example, or the worked examples under
[`examples/`](https://github.com/elijahr/lockfreequeues/tree/master/examples).

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

Examples are in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory:

```sh
nimble examples
```

## References

- Juho Snellman's ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/)
- Mamy Ratsimbazafy's [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature)
- Henrique F Bucher's ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370)
