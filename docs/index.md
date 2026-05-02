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

Linked segment implementations that grow as needed. Use DEBRA+ epoch-based reclamation (via [nim-debra](https://github.com/elijahr/nim-debra)) for safe memory deallocation.

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

### Unbounded Queue (single-producer, single-consumer)

`UnboundedSipsic` does not need DEBRA reclamation: the producer and consumer
each hold their own segment pointer and the consumer-side advance is the only
freer.

```nim
import lockfreequeues

# Unbounded SPSC queue with segment size 64
var queue = newUnboundedSipsic[64, int]()

queue.push(42)  # Never fails - grows as needed
let item = queue.pop()  # some(42)
```

### Unbounded Queue (multi-producer, multi-consumer)

The MP/MC unbounded variants need a `DebraManager` for safe segment
reclamation, plus a per-thread handle for each producer and consumer:

```nim
import options
import debra
import lockfreequeues

var manager = initDebraManager[4]()
var queue = newUnboundedMupmuc[64, int, 4](addr manager)

let producerHandle = registerThread(manager)
let consumerHandle = registerThread(manager)

var producer = queue.getProducer(producerHandle)
var consumer = queue.getConsumer(consumerHandle)

producer.push(42)
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

Examples are in the [examples](https://github.com/elijahr/lockfreequeues/tree/master/examples) directory:

```sh
nimble examples
```

## References

- Juho Snellman's ["I've been writing ring buffers wrong all these years"](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/)
- Mamy Ratsimbazafy's [research on SPSC channels](https://github.com/mratsim/weave/blob/master/weave/cross_thread_com/channels_spsc.md#litterature)
- Henrique F Bucher's ["Yes, You Have Been Writing SPSC Queues Wrong Your Entire Life"](http://www.vitorian.com/x1/archives/370)
