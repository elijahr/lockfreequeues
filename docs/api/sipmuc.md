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

## API

### Queue Operations

```nim
proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T]
proc push*[N, C, T](self: var Sipmuc[N, C, T], item: T): bool
proc push*[N, C, T](self: var Sipmuc[N, C, T], items: openArray[T]): Option[HSlice[int, int]]
proc getConsumer*[N, C, T](self: var Sipmuc[N, C, T]): Consumer[N, C, T]
proc capacity*[N, C, T](self: Sipmuc[N, C, T]): int
```

### Consumer Operations

```nim
proc pop*[N, C, T](self: var Consumer[N, C, T]): Option[T]
proc pop*[N, C, T](self: var Consumer[N, C, T], count: int): Option[seq[T]]
```

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
