# Sipsic

Single-producer, single-consumer (SPSC) bounded queue. Both pushing and
popping are wait-free.

## Overview

- **Push**: Wait-free (single producer, no coordination)
- **Pop**: Wait-free (single consumer, no coordination)
- **Capacity**: Fixed at compile time

Sipsic occupies the SPSC quadrant of the bounded queue family. Because
there is exactly one producer and exactly one consumer, no CAS or
per-slot sequence protocol is needed: the producer owns `tail`, the
consumer owns `head`, and ring-buffer arithmetic on `N+1` physical
slots distinguishes empty from full.

## Usage

```nim
import lockfreequeues

# Capacity 64
var queue = initSipsic[64, int]()

# Single producer pushes directly
discard queue.push(42)
discard queue.push(123)

# Single consumer pops directly (no handle needed — there's only one)
let item = queue.pop()  # some(42)
```

## Type Parameters

- `N: static int` — Queue capacity (power of 2 recommended)
- `T` — Item type

The full proc/type signatures and per-symbol docs are auto-generated
from source by the `:::` directive at the bottom of this page.

## Example: Single-Pipeline Pattern

```nim
import lockfreequeues
import options

var queue = initSipsic[256, int]()

proc producer() {.thread.} =
  for i in 0..<1000:
    while not queue.push(i):
      discard  # Queue full, retry

proc consumer() {.thread.} =
  while true:
    let item = queue.pop()
    if item.isSome:
      # Process item
      discard
```

## Typestate notes

Sipsic does not require producer- or consumer-binding handles: there
is only one of each by construction. The typestate machinery used
internally (see `spsc_push` / `spsc_pop` in
`src/lockfreequeues/typestates/`) is a sequencing aid for the push/pop
verbs themselves, not a binding API exposed to callers. For the
broader slot-ownership model that all bounded variants share, see
[Slot Ownership Typestates](../guide/slot-ownership-typestates.md).

## See also

- [Safety Model](../guide/safety-model.md) — happens-before guarantees
  and ordering semantics.
- [Slot Ownership Typestates](../guide/slot-ownership-typestates.md) —
  the shared internal state machine across all bounded variants.

::: lockfreequeues/sipsic
