# Memory Management

> Current as of v4.2.0; DEBRA integration patterns may evolve.

How `lockfreequeues` interacts with the memory model, what guarantees the
queues provide vs. what the user must guarantee, the role of cache-line
padding, item-type constraints under ARC / ORC, and the DEBRA epoch-based
reclamation hooks used by the unbounded multi-thread variants.

For the broader thread-safety contract, see [Safety Model](safety-model.md).

## The memory model

### What lockfreequeues guarantees

_(Coming in v4.2.0)_

### What the user must guarantee

_(Coming in v4.2.0)_

### Acquire / release ordering, in plain English

_(Coming in v4.2.0)_

```nim
# (example coming)
```

## Cache-line padding

### Why fields are padded

_(Coming in v4.2.0)_

### How padding interacts with sanitisers

_(Coming in v4.2.0)_

### Auditing your own types

_(Coming in v4.2.0)_

```nim
# (example coming)
```

## Item types and ARC / ORC

The default policy: queue item types must be lock-free. See
[Safety Model](safety-model.md#item-type-requirements) for the full
contract.

### `ref T` is rejected by default

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Why the rejection is a feature

_(Coming in v4.2.0)_

### `-d:allowNonLockFreeQueueItems` escape hatch

_(Coming in v4.2.0)_

```nim
# (example coming)
```

## DEBRA integration

DEBRA is the epoch-based reclamation scheme used by the unbounded
multi-thread variants (`UnboundedSipmuc`, `UnboundedMupsic`,
`UnboundedMupmuc`) to retire and free segments safely under contention.

### What DEBRA solves (epoch-based reclamation)

_(Coming in v4.2.0)_

### Hooks lockfreequeues exposes

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### When to enable

_(Coming in v4.2.0)_

### Versioning note

DEBRA internals may change; treat the patterns documented here as
current-as-of-v4.2.0. See the
[DEBRA repository](https://github.com/elijahr/nim-debra) for upstream
changes.
