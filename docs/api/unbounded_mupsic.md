# UnboundedMupsic

Unbounded multiple-producer, single-consumer (MPSC) queue using linked segments.

## Overview

`UnboundedMupsic` provides an unbounded MPSC queue where multiple producers feed a single consumer. Uses DEBRA+ epoch-based memory reclamation (via [nim-debra](https://github.com/elijahr/nim-debra)) and a per-slot committed flag inside each segment for safe concurrent writes.

> **Note:** This per-slot committed flag is the *segment-local* publication
> mechanism for the unbounded queues. It is distinct from the per-slot
> sequence-counter protocol used by the bounded variants (`Mupmuc`, `Mupsic`,
> `Sipmuc`). Unbounded segments are single-use linked nodes (no generation
> rollover), so the simpler one-shot committed flag is sufficient. See
> [slot-ownership-typestates.md](../slot-ownership-typestates.md) for the
> full distinction.

**Performance characteristics:**

- **Push**: Lock-free (CAS coordination between producers)
- **Pop**: Wait-free (bounded steps)

## Usage

```nim
import lockfreequeues

let manager = newEpochManager()
var queue = newUnboundedMupsic[64, int](manager)

# Each producer gets a handle
var producer1 = queue.getProducer()
var producer2 = queue.getProducer()

# Producers push concurrently
producer1.push(42)
producer2.push(123)

# Single consumer pops
let item = queue.pop()  # some(42) or some(123)
```

## When to Use

Choose `UnboundedMupsic` when:

- Multiple sources feed a single processor
- Number of producers may change at runtime
- Event collection or log aggregation patterns
- Cannot predetermine maximum queue size

Choose bounded `Mupsic` instead when:

- Memory must be bounded
- Producer count is fixed at compile time
- Queue size is predictable

## API

::: lockfreequeues/unbounded_mupsic
