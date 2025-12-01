# UnboundedSipmuc

Unbounded single-producer, multiple-consumer (SPMC) queue using linked segments.

## Overview

`UnboundedSipmuc` provides an unbounded SPMC queue where a single producer distributes work to multiple consumers. Uses epoch-based memory reclamation for safe segment deallocation.

**Performance characteristics:**

- **Push**: Wait-free (bounded steps)
- **Pop**: Lock-free (CAS coordination between consumers)

## Usage

```nim
import lockfreequeues

let manager = newEpochManager()
var queue = newUnboundedSipmuc[64, int](manager)

# Producer pushes
queue.push(42)

# Each consumer gets a handle
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
