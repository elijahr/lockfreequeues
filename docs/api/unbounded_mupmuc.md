# UnboundedMupmuc

Unbounded multiple-producer, multiple-consumer queue using linked segments.

## Overview

`UnboundedMupmuc` provides an unbounded MPMC queue with fully concurrent access. Uses epoch-based memory reclamation and a committed flag for safe concurrent operations.

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
