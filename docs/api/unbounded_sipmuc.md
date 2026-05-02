# UnboundedSipmuc

Unbounded single-producer, multiple-consumer (SPMC) queue using linked segments.

## Overview

`UnboundedSipmuc` provides an unbounded SPMC queue where a single producer distributes work to multiple consumers. Uses DEBRA+ epoch-based memory reclamation (via [nim-debra](https://github.com/elijahr/nim-debra)) for safe segment deallocation, and a per-slot committed flag inside each segment for safe publication to concurrent consumers.

> **Note:** This per-slot committed flag is the *segment-local* publication
> mechanism for the unbounded queues. It is distinct from the per-slot
> sequence-counter protocol used by the bounded variants (`Mupmuc`, `Mupsic`,
> `Sipmuc`). Unbounded segments are single-use linked nodes (no generation
> rollover), so the simpler one-shot committed flag is sufficient. See
> [slot-ownership-typestates.md](../slot-ownership-typestates.md) for the
> full distinction.

**Performance characteristics:**

- **Push**: Wait-free (bounded steps)
- **Pop**: Lock-free (CAS coordination between consumers)

## Usage

```nim
import lockfreequeues
import debra

# Auto-create overload: queue owns a private DebraManager (torn down
# with the queue). For multi-queue setups sharing a manager, see the
# explicit `(manager, strategy)` overload.
const MaxThreads = 4
var queue = newUnboundedSipmuc[64, int, MaxThreads]()

# Producer pushes
queue.push(42)

# Each consumer gets a handle (auto-registers a thread slot)
var consumer1 = queue.getConsumer()
var consumer2 = queue.getConsumer()

# Consumers compete for items
let item = consumer1.pop()  # some(42) - one consumer wins
```

## When to Use

Choose `UnboundedSipmuc` when:

- Single source distributes to multiple workers
- Number of consumers may change at runtime
- Workload is bursty or unpredictable
- Cannot predetermine maximum queue size

Choose bounded `Sipmuc` instead when:

- Memory must be bounded
- Consumer count is fixed at compile time
- Queue size is predictable

## API

::: lockfreequeues/unbounded_sipmuc
