# UnboundedMupsic

Unbounded multiple-producer, single-consumer queue using linked segments.

## Overview

`UnboundedMupsic` provides an unbounded MPSC queue where multiple producers feed a single consumer. Uses epoch-based memory reclamation and a committed flag for safe concurrent writes.

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
