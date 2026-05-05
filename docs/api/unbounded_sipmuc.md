# UnboundedSipmuc

Unbounded single-producer, multiple-consumer (SPMC) queue using linked segments.

## Overview

`UnboundedSipmuc` provides an unbounded SPMC queue where a single producer distributes work to multiple consumers. Uses DEBRA+ epoch-based memory reclamation (via [nim-debra](https://github.com/elijahr/nim-debra)) for safe segment deallocation, and a segment-level `tail` atomic for safe publication to concurrent consumers.

> **Note:** With a single producer there is no race on the slot itself,
> so each segment carries one `tail: Atomic[int]` rather than a per-slot
> commit/sequence marker. The producer writes the item then bumps `tail`
> with release ordering; consumers acquire-load `tail` and treat any
> slot below it as fully published. The unbounded MP variants
> (`UnboundedMupsic`, `UnboundedMupmuc`) need a per-slot committed flag
> because multiple producers race on `tail` via CAS to claim a slot
> before writing, so `tail` can advance past not-yet-written slots; the
> bounded MP variants use a per-slot sequence-counter protocol with
> generation rollover. See [slot-ownership-typestates.md](../slot-ownership-typestates.md)
> for the full distinction across all four bounded × unbounded × SP × MP
> combinations.

**Performance characteristics:**

- **Push**: Wait-free (bounded steps)
- **Pop**: Lock-free (CAS coordination between consumers)

## Usage

```nim
import lockfreequeues

# Generic params are [SegmentSize, ItemType, MaxThreads]; auto-create
# overload (no args) heap-allocates a private DebraManager owned by
# the queue. For multi-queue setups sharing a manager, use the
# explicit `(manager, strategy)` overload instead.
var queue = newUnboundedSipmuc[64, int, 4]()

# Producer pushes
queue.push(42)

# Each consumer gets a handle (auto-registers a thread slot in the
# manager). Slots are not released until the manager is destroyed, so
# reuse one handle per long-running consumer thread rather than calling
# `getConsumer()` repeatedly.
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
