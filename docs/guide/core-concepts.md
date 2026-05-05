# Core Concepts

The conceptual foundation for the rest of the guide: bounded vs unbounded
queues, lock-free vs wait-free progress guarantees, the SPSC / SPMC / MPSC /
MPMC quadrant, and how capacity and segments work under the hood.

Read this once, then return to the topic-specific guides as needed.

## Bounded vs Unbounded

### When you know the upper bound

_(Coming in v4.2.0)_

### When you don't

_(Coming in v4.2.0)_

### Backpressure semantics

_(Coming in v4.2.0)_

For the full decision guide, see
[Bounded vs Unbounded](bounded-vs-unbounded.md).

## Lock-Free vs Wait-Free

### Per-operation guarantees

_(Coming in v4.2.0)_

### Where lockfreequeues sits

_(Coming in v4.2.0)_

For the slot-level state machine that backs push and pop, see
[Slot Ownership Typestates](slot-ownership-typestates.md). For the broader
thread-safety contract, see [Safety Model](safety-model.md).

## SPSC / SPMC / MPSC / MPMC quadrant

The four producer/consumer patterns and the queue type that implements each.

### One-table summary

_(Coming in v4.2.0; placeholder table)_

| Producers | Consumers | Bounded type | Unbounded type |
|-----------|-----------|--------------|----------------|
| 1 | 1 | _(coming)_ | _(coming)_ |
| 1 | many | _(coming)_ | _(coming)_ |
| many | 1 | _(coming)_ | _(coming)_ |
| many | many | _(coming)_ | _(coming)_ |

For per-type API reference, see the API pages: `Sipsic`, `Sipmuc`, `Mupsic`,
`Mupmuc` (and the `Unbounded*` variants).

### When to pick which

_(Coming in v4.2.0)_

### Why MPMC is more expensive than SPSC

_(Coming in v4.2.0)_

## Capacity, segments, and rollover

### Bounded ring buffer model

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Unbounded segment-list model

_(Coming in v4.2.0)_

```nim
# (example coming)
```
