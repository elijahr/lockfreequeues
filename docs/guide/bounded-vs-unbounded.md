# Bounded vs Unbounded

!!! warning "v5.0.0 — Static Thread-Affinity Endpoint API"

    v5.0.0 is a hard-break release. The v4.x `Bound[T, Tag, BQueue[...]]` endpoint /
    `Bound[T, Tag, Queue[...]]` endpoint / `attach()` / `bindConsumer()` API is REMOVED;
    replaced by the `Unbound → Bound → Closed` endpoint lifecycle.
    See [`docs/migrations/v5.0.0.md`](../migrations/v5.0.0.md) for the
    full migration guide + v4.x → v5.0.0 cookbook + breaking-change
    checklist.


A decision guide for picking between the bounded ring-buffer queue
(`BQueue`, constructed via `newSpscQueue` / `newSpmcQueue` /
`newMpscQueue` / `newMpmcQueue`) and the unbounded segment-linked
queue (`Queue`, constructed via `newUnboundedSpscQueue` /
`newUnboundedSpmcQueue` / `newUnboundedMpscQueue` /
`newUnboundedMpmcQueue`).

If you have not yet read the conceptual overview, start with
[Core Concepts](core-concepts.md). The high-level "bounded means fixed
capacity, unbounded grows as needed" framing is covered there; this page
is the deeper decision-helper for cases where the choice is non-obvious.

## When to choose bounded

### Backpressure as a feature

A bounded queue rejects pushes when full, and that rejection is often the
correct behaviour. Real-time audio is the canonical example: if the
producer thread cannot get its sample buffer onto the queue within one
frame, the right answer is usually to drop the frame, not to grow memory
until the consumer eventually catches up. A 64-sample buffer at 44.1 kHz
gives the producer 1.45 ms to publish; if it misses, the audio system
absorbs a glitch and moves on.

The bounded `push` returns `false` exactly to enable that policy:

```nim
import lockfreequeues

var queue = newSpscQueue[float32, 64]()
var sample = 0.5'f32

if not queue.push(sample):
  # Frame dropped — increment a counter, log to a non-blocking ring,
  # whatever your domain wants. Do NOT block the audio thread.
  discard
```

The bounded queue forces you to confront the question. An unbounded queue
silently accepts the work, which is either fine (event aggregation) or a
production incident waiting to happen (a slow consumer turning into a
runaway memory leak).

### Memory upper bound is a hard requirement

Embedded targets, kernel-adjacent code, and any deployment with a hard
memory ceiling cannot tolerate "the queue might allocate". A bounded queue
allocates exactly once at construction — `N * sizeof(T)` plus a few
cache-line-aligned counters — and never again.

```nim
import lockfreequeues

# Total queue memory: ~(256 * 8) + 2 * 64 = 2176 bytes for an int64 queue.
# Predictable enough to fit in an L2 cache budget.
var q = newSpscQueue[int64, 256]()
```

The number is exact, knowable at compile time, and visible in
`sizeof(q)`. No segment list is ever linked, no allocator is ever called
during `push` or `pop`.

### CI-friendly determinism

Bounded queues run identically on every machine. There is no allocator
to tune, no GC to interact with the segment linking, no platform-specific
malloc behaviour to absorb. A test that fills a
`newMpmcQueue[int, 1024, 4, 4]()` to capacity and asserts `push` starts
returning `false` exhibits the same behaviour on a CI runner with 2 GB of
RAM as on a developer laptop with 64 GB.

## When to choose unbounded

### When push must always succeed

Some workloads cannot drop. Log aggregation across hundreds of producers,
event collection during a load test, work scheduling where the producer
already paid for the work and dropping means losing it. For these, the
unbounded variants offer a `push` that does not return a "rejected"
signal:

```nim
import options
import lockfreequeues

# stEager strategy, segment size 64, debra registry capacity 8.
var queue = newUnboundedMpscQueue[int, stEager, 64, 8]()
var producer = queue.getProducer()
# Multi-cardinality unbounded views register with the queue's epoch
# manager on first use. Call attach() on the thread that will push.
discard producer.bindToThread()  # v5.0.0: replaces v4.x attach()
producer.push(42)  # Always succeeds (until allocator fails).
```

Note the absence of a return value. The unbounded `push` either succeeds
or raises (an `OutOfMem` from the system allocator); there is no
`false` to ignore.

### Cost: segment allocation on overflow

When the current tail segment fills, the producer allocates a fresh
segment and links it. Allocation cost is one `aligned_alloc` plus a few
atomic stores to publish the new segment. On a typical Linux x86_64
machine that is in the low single-digit microseconds — orders of
magnitude more than a `push` into an already-warm bounded slot, but
only paid once per `S` items. Pick `S` such that the amortized cost
disappears: for an MPSC queue ingesting 10k events/s with `S = 256`,
you allocate roughly 39 segments per second, which is invisible.

The segments are aligned to a cache-line boundary so the per-segment
metadata (the `next`, `head`, and `tail` atomics) does not false-share
with adjacent segments — see
[Memory Management → Cache-line padding](memory-management.md#cache-line-padding)
for why this matters.

### Deallocation timing under DEBRA

Retired segments cannot be freed immediately. A consumer thread that
has just advanced past a segment may still be holding a pointer into
its data; freeing the segment under it would be a use-after-free. The
multi-cardinality unbounded shapes hand retired segments to DEBRA, which
defers the actual `free` until every active thread has crossed an epoch
boundary. The mechanism is invisible at the API level once threads have
registered: each multi-cardinality view calls `attach()` (or
`bindConsumer()` for the unbounded MPSC consumer) on its operating
thread before its first op, and reclamation then happens in the
background.

See [Memory Management → DEBRA integration](memory-management.md#debra-integration)
for the attach-time registration model and the `stManual` vs `stEager`
deallocation strategy switch.

## Capacity selection (bounded)

### Power-of-2 sizing rationale

There is a folk rule in lock-free queue lore: "always pick a power of
two for the capacity, so the modulo wrap reduces to a bitmask".
`lockfreequeues` does not require this — any positive `N` compiles, and
the wrap is implemented with arithmetic that handles arbitrary `N`. But
on hot paths the compiler can sometimes lower `idx mod N` to
`idx and (N-1)` when `N` is a power of two, which is a single AND
instruction instead of an integer divide.

```nim
import lockfreequeues

# Power-of-2: bitmask wrap is plausible.
var q1 = newSpscQueue[int, 1024]()

# Arbitrary: modulo wrap, slightly more work per push/pop.
var q2 = newSpscQueue[int, 1000]()
```

If you are at the throughput edge — millions of ops/s, every cycle
counts — pick a power of two. For everyday use, pick the capacity that
matches your domain: `64` for an audio frame, `256` for an HTTP worker
pool, whatever number falls out of the requirement.

### Choosing N: throughput vs memory

The capacity question is really a question about burst absorption.
Steady-state throughput is rarely the bottleneck for a bounded queue —
if the producer's average rate exceeds the consumer's, no finite buffer
saves you. What `N` buys is tolerance for momentary mismatches: the
producer briefly exceeds the consumer's drain rate, the queue fills, the
consumer catches up, the queue drains.

Rule of thumb: pick `N` such that the 99th-percentile burst fits, plus
a safety margin. To measure the 99th-percentile burst empirically:
instrument the queue's `len()` (or, for queues without `len`, count
push attempts vs successful pushes over a window) for a representative
workload, take the 99th percentile of the high-water mark, and add 25-50%
slack.

For empirical numbers and the throughput-vs-capacity curve, see
[Benchmarks](../benchmarks.md) and
[Performance Tuning](performance-tuning.md#capacity-segment-sizing).

### Multiple producers: contention scaling

The multi-producer shapes (`newMpscQueue` / `newMpmcQueue`) add a CAS
loop on the producer side. Under high contention — say 16 producer threads
on a 16-core machine all hammering the same queue — retries multiply,
throughput per thread drops, and you reach a regime where adding producers
does not add throughput. The mitigation is partitioning: instead of one
`newMpmcQueue[int, 1024, 16, 16]()`, use four
`newMpmcQueue[int, 1024, 4, 4]()` queues with producer-side hashing.
The trade-off is a more complex consumer that drains all four.

## Segment size selection (unbounded)

### Default segment size

`S` is required and not defaulted — the unbounded constructors take it
as a generic parameter exactly like `N` for bounded queues. There is no
"default" that the library picks for you, because the right value is
domain-dependent. For most workloads, a value in the range 64-512 is a
reasonable starting point.

### When to override

Two regimes pull `S` in opposite directions:

- **Sustained high throughput** wants larger `S`. Each segment
  allocation is a microsecond-scale operation; if the workload is
  10 M items/s, you want to amortize that allocation over more items,
  so `S = 1024` or `S = 4096` reduces the allocation rate to something
  the system never notices.
- **Bursty, low average rate** wants smaller `S`. A one-off burst of
  100 items into a segment with `S = 4096` wastes ~3990 slots of
  allocation — fine if memory is plentiful, painful if not. `S = 64`
  keeps the per-segment overhead small and lets DEBRA reclaim sooner.

```nim
import lockfreequeues

# Sustained ingest, 1 MHz event rate: minimize allocation churn.
var ingest = newUnboundedMpscQueue[int, stEager, 1024, 8]()

# Sporadic bursts of <100 events from each of 4 sources: smaller S
# keeps the working set cache-friendly.
var sporadic = newUnboundedMpscQueue[int, stEager, 64, 4]()
```

If you are unsure, start at `256` and tune from measurement.

## Backpressure patterns

### Spin-and-retry

The simplest pattern. The producer loops on `push` until the queue
accepts the item, yielding to the scheduler between attempts so it does
not starve the consumer:

```nim
import os
import lockfreequeues

var queue = newSpscQueue[int, 16]()

proc producePersistent(item: int) =
  while not queue.push(item):
    sleep(0)  # Yield; do NOT busy-spin without a yield.
```

This is appropriate when you genuinely cannot drop and the producer can
afford to wait. It is inappropriate on a real-time audio thread, on a
GC thread, or anywhere with a deadline.

### Fail-fast (`Option` / `bool` returns)

The bounded queues' `push` returns `bool`; their `pop` returns
`Option[T]`. Use those returns directly — let the caller decide:

```nim
import options
import lockfreequeues

var queue = newSpscQueue[int, 16]()

if queue.push(42):
  echo "accepted"
else:
  echo "queue full — dropping"

let item = queue.pop()
if item.isSome:
  echo "got ", item.get
else:
  echo "queue empty"
```

This is the pattern for real-time code, soft-real-time servers, and
anywhere a backed-up consumer should not stall the producer.

### Sleep-then-retry with backoff

Between pure spin and pure fail-fast: retry with an increasing sleep,
so transient contention resolves quickly but a sustained mismatch does
not burn CPU:

```nim
import os
import lockfreequeues

var queue = newSpscQueue[int, 64]()

proc pushWithBackoff(item: int): bool =
  var delayMs = 0
  for attempt in 0 .. 9:
    if queue.push(item):
      return true
    sleep(delayMs)
    delayMs = min(max(1, delayMs * 2), 32)
  return false  # Give up after 10 attempts.
```

The numbers (10 attempts, cap at 32 ms) are illustrative — pick values
that match your latency budget. If the queue routinely fills for 200 ms
at a time, 10 short retries are not enough; if you need <1 ms response,
do not sleep at all.

## Trade-offs at a glance

| Dimension | Bounded | Unbounded |
|-----------|---------|-----------|
| Memory predictability | Exact: `N * sizeof(T)` + counters | Grows in `S`-sized chunks until allocator fails |
| Latency tail | No allocation in `push`/`pop`; tail is the CAS loop only | Allocation on segment overflow adds a microsecond-scale spike |
| Throughput peak | Higher when capacity fits the burst; near-zero per-op overhead | Slightly lower per-op due to segment indirection |
| Backpressure | Built in: `push` returns `false` when full | None: producer must self-rate-limit |
| GC interaction | None at runtime | Multi-thread variants use DEBRA; segments aligned-alloc'd via libc, not the Nim heap |
| Complexity | Simplest possible: one array + two cursors | Linked list + epoch reclamation under contention |

A reasonable default: start bounded, with `N` sized to the 99th-percentile
burst plus 25% slack. Move to unbounded only when you have measured a
specific workload that the bounded variant cannot serve, or when "drop"
is not an acceptable behaviour for any reason.
