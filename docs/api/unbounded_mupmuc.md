# UnboundedMupmuc

Unbounded multiple-producer, multiple-consumer (MPMC) queue using linked segments.

## Overview

`UnboundedMupmuc` provides an unbounded MPMC queue with fully concurrent access. Uses DEBRA+ epoch-based memory reclamation (via [nim-debra](https://github.com/elijahr/nim-debra)) and a per-slot committed flag inside each segment for safe concurrent operations.

> **Note:** This per-slot committed flag is the *segment-local* publication
> mechanism for the unbounded queues. It is distinct from the per-slot
> sequence-counter protocol used by the bounded variants (`Mupmuc`, `Mupsic`,
> `Sipmuc`). Unbounded segments are single-use linked nodes (no generation
> rollover), so the simpler one-shot committed flag is sufficient. See
> [slot-ownership-typestates.md](../slot-ownership-typestates.md) for the
> full distinction.

**Performance characteristics:**

- **Push**: Lock-free (CAS coordination between producers)
- **Pop**: Lock-free (CAS coordination between consumers)

## Usage

```nim
import lockfreequeues

let manager = newEpochManager()
var queue = newUnboundedMupmuc[64, int](manager)

# Each thread gets its own handle
var producer = queue.getProducer()
var consumer = queue.getConsumer()

# Concurrent operations
producer.push(42)
let item = consumer.pop()  # some(42)
```

## When to Use

Choose `UnboundedMupmuc` when:

- Multiple producers and consumers work concurrently
- Thread pools with dynamic producer/consumer counts
- Job scheduling systems
- Cannot predetermine maximum queue size

Choose bounded `Mupmuc` instead when:

- Memory must be bounded
- Producer/consumer counts are fixed at compile time
- Queue size is predictable

## API

::: lockfreequeues/unbounded_mupmuc
