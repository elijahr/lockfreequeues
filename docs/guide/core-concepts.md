# Core Concepts

The conceptual foundation for the rest of the guide: bounded vs unbounded
queues, lock-free vs wait-free progress guarantees, the SPSC / SPMC / MPSC /
MPMC quadrant, and how capacity and segments work under the hood.

Read this once, then return to the topic-specific guides as needed.

## Bounded vs Unbounded

### When you know the upper bound

A *bounded* queue has a fixed compile-time capacity `N`. The queue allocates
its storage once, never grows, and rejects further pushes when full (`push`
returns `false`). This is the right choice when your traffic has a known
ceiling — an audio buffer at 64 samples, an HTTP worker pool with 256
in-flight requests, a sensor pipeline at 1 kHz with a 100 ms tolerance.

Bounded queues are wait-free for SPSC and lock-free for the contended
multi-thread variants. No allocation happens during operation. Memory cost
is exactly `N * sizeof(T)` plus a few cache-line-aligned counters.

### When you don't

An *unbounded* queue grows segment by segment. Push always succeeds (until
the allocator runs out). The cost is per-segment allocation when the
current segment fills, and — for the multi-thread unbounded variants —
DEBRA epoch-based reclamation to free retired segments safely under
contention.

Pick unbounded when bursts can dwarf the steady-state rate (log
aggregation across hundreds of producers, event collection during a load
test, work scheduling where you would rather grow memory than drop work).

### Backpressure semantics

A bounded queue full means `push` returns `false`. Whether you retry,
sleep, or drop is application policy. An unbounded queue has no
"full" — backpressure has to come from somewhere else (rate limiting at
the producer, monitoring on segment count, OOM as a last resort).

For the full decision guide, see
[Bounded vs Unbounded](bounded-vs-unbounded.md).

## Lock-Free vs Wait-Free

### Per-operation guarantees

Two progress guarantees, in increasing strength:

- **Lock-free**: at least one thread makes progress on every step of the
  algorithm. Individual threads may retry their CAS loop indefinitely, but
  the system as a whole never stalls. A preempted thread cannot stop
  others.
- **Wait-free**: every thread completes its operation in a bounded number
  of steps, regardless of what other threads are doing. The strongest
  progress guarantee available without locks.

Mutex-based code is neither. A holder that gets preempted while holding
the lock blocks every other thread until it is rescheduled.

### Where lockfreequeues sits

| Variant family | push | pop |
|----------------|------|-----|
| `Sipsic` (bounded SPSC) | wait-free | wait-free |
| `Sipmuc` (bounded SPMC) | wait-free | lock-free |
| `Mupsic` (bounded MPSC) | lock-free | wait-free |
| `Mupmuc` (bounded MPMC) | lock-free | lock-free |
| `UnboundedSipsic` | wait-free | wait-free |
| `UnboundedSipmuc` (unbounded SPMC) | wait-free | lock-free |
| `UnboundedMupsic` (unbounded MPSC) | lock-free | wait-free |
| `UnboundedMupmuc` (unbounded MPMC) | lock-free | lock-free |

The single-side-of-each-pair operations (the `Sip*` and `*Sic` ends) are
wait-free because there is no CAS contention — only one thread races for
that cursor. The contended sides use a CAS loop and are lock-free.

For the slot-level state machine that backs push and pop, see
[Slot Ownership Typestates](slot-ownership-typestates.md). For the broader
thread-safety contract, see [Safety Model](safety-model.md).

## SPSC / SPMC / MPSC / MPMC quadrant

The four producer/consumer patterns and the queue type that implements each.

### One-table summary

| Producers | Consumers | Bounded type | Unbounded type |
|-----------|-----------|--------------|----------------|
| 1 | 1 | `Sipsic` | `UnboundedSipsic` |
| 1 | many | `Sipmuc` | `UnboundedSipmuc` |
| many | 1 | `Mupsic` | `UnboundedMupsic` |
| many | many | `Mupmuc` | `UnboundedMupmuc` |

The naming is mnemonic: **Si**ngle vs **Mu**ltiple, **p**roducer, **s**ingle
vs multiple, **c**onsumer. `Sipsic` = Single-producer / Single-consumer.
`Mupmuc` = Multi-producer / Multi-consumer.

For per-type API reference, see the API pages: `Sipsic`, `Sipmuc`, `Mupsic`,
`Mupmuc` (and the `Unbounded*` variants).

### When to pick which

The choice is made by counting threads, not by guessing which queue is
"fastest". A queue used incorrectly — say, two producer threads sharing a
`Sipsic` — has undefined behaviour.

- One producer, one consumer: use `Sipsic`. Wait-free both sides; lowest
  per-op cost in the library.
- One producer, many consumers (fan-out): use `Sipmuc`. The producer side
  stays wait-free; consumers race a CAS to claim a slot.
- Many producers, one consumer (fan-in, the most common server pattern):
  use `Mupsic`. Producers race; consumer is wait-free.
- Many on both sides: use `Mupmuc`. Both sides race.

If your producer or consumer count is "1 most of the time but occasionally
2", you still need the multi-side variant. The library cannot detect at
runtime that you are temporarily violating the contract.

### Why MPMC is more expensive than SPSC

Every additional contended side adds a CAS loop and a per-slot sequence
counter. `Sipsic` writes the item, then advances a single tail cursor with
a release store — no CAS. `Mupmuc` has to publish the item with a release
store, advance the tail with a CAS that may lose to other producers, and
do the same dance on the consumer side. Under contention, retries
multiply.

The published [Benchmarks](../benchmarks.md) page shows the empirical gap;
expect ~3-5× difference between SPSC and uncontended MPMC, growing with
producer count.

## Capacity, segments, and rollover

### Bounded ring buffer model

A bounded queue is a flat array of `N` slots plus head and tail cursors.
Producers advance the tail, consumers advance the head, and both wrap
modulo `N` (or `N + 1` for `Sipsic`, which uses one extra slot to
distinguish full from empty without a separate count field).

```nim
import options
import lockfreequeues

# Capacity 8: 8 slots usable, plus 1 sentinel for SPSC.
var queue = initSipsic[8, int]()

discard queue.push(1)
discard queue.push(2)
echo queue.capacity()  # 8
echo queue.pop()       # Some(1)
```

When the tail catches the head (queue full) `push` returns `false`. When
the head catches the tail (queue empty) `pop` returns `none`. Generation
rollover for the multi-producer / multi-consumer bounded variants is
handled by Vyukov per-slot sequence counters — see
[Slot Ownership Typestates → Publication Protocol](slot-ownership-typestates.md#publication-protocol-bounded-vs-unbounded)
for the protocol that makes wraparound races structurally impossible.

### Unbounded segment-list model

An unbounded queue is a singly-linked list of segments, where each
segment is a fixed-size array of `S` slots. Producers fill the current
tail segment until it is exhausted, then atomically link a freshly
allocated segment and continue. Consumers drain the head segment until
it is empty, then advance to the next segment and (for the multi-thread
variants) hand the retired segment to DEBRA for safe reclamation.

```nim
import options
import lockfreequeues

# Segment size 64 — each segment holds 64 ints. The queue grows
# segment-by-segment as load demands.
var queue = newUnboundedSipsic[64, int]()

queue.push(1)
queue.push(2)
echo queue.segmentCount()  # 1 (no overflow yet)
echo queue.pop()           # Some(1)
```

Segment size `S` is the granularity of allocation: small `S` means more
allocations under sustained load, large `S` means more wasted memory at
low load. See
[Bounded vs Unbounded → Segment size selection](bounded-vs-unbounded.md#segment-size-selection-unbounded)
for the trade-off.
