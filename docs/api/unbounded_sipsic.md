# UnboundedSipsic

Unbounded single-producer, single-consumer (SPSC) queue using linked segments.

## Overview

`UnboundedSipsic` provides an unbounded SPSC queue that grows dynamically as items are added. Single-producer, single-consumer means there is no DEBRA manager: the queue can safely free retired segments inline once the consumer has advanced past them.

**Performance characteristics:**

- **Push**: Wait-free (bounded steps)
- **Pop**: Wait-free (bounded steps)

## Usage

```nim
import lockfreequeues

# Generic params are [SegmentSize, ItemType]. SPSC needs no DEBRA
# manager and no MaxThreads parameter — the constructor takes none.
var queue = newUnboundedSipsic[64, int]()

# Push items (never fails - grows as needed)
queue.push(42)
queue.push(123)

# Pop items
let item = queue.pop()  # some(42)
let items = queue.pop(2)  # some(@[123])
```

## When to Use

Choose `UnboundedSipsic` when:

- Producer and consumer run on separate threads
- Workload is bursty or unpredictable
- Cannot predetermine maximum queue size
- Memory growth is acceptable

Choose bounded `Sipsic` instead when:

- Memory must be bounded
- Working in real-time systems
- Queue size is predictable

## API

::: lockfreequeues/unbounded_sipsic
