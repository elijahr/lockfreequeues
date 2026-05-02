# Sipmuc

Single-producer, multiple-consumer (SPMC) bounded queue.

## Overview

- **Push**: Wait-free (single producer, no coordination needed)
- **Pop**: Lock-free (consumers coordinate via CAS)
- **Capacity**: Fixed at compile time

## Usage

```nim
import lockfreequeues

# Create queue with capacity 64 and max 4 consumers
var queue = initSipmuc[64, 4, int]()

# Producer pushes directly
discard queue.push(42)
discard queue.push(123)

# Consumers must get a handle first
var consumer = queue.getConsumer()
let item = consumer.pop()  # some(42)
```

## Type Parameters

- `N: static int` - Queue capacity (power of 2 recommended)
- `C: static int` - Maximum number of consumers
- `T` - Item type

The full proc/type signatures and per-symbol docs are auto-generated
from source by the `:::` directive at the bottom of this page.

## Example: Fan-Out Pattern

```nim
import lockfreequeues
import std/os

var queue = initSipmuc[256, 4, int]()

# Producer thread
proc producer() {.thread.} =
  for i in 0..<1000:
    while not queue.push(i):
      discard  # Queue full, retry

# Consumer threads
proc consumer() {.thread.} =
  var c = queue.getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      # Process item
      discard
```

::: lockfreequeues/sipmuc
