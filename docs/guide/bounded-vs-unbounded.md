# Bounded vs Unbounded

A decision guide for picking between the bounded ring-buffer queues
(`Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`) and the unbounded segment-linked
variants (`UnboundedSipsic`, `UnboundedSipmuc`, `UnboundedMupsic`,
`UnboundedMupmuc`).

If you have not yet read the conceptual overview, start with
[Core Concepts](core-concepts.md).

## When to choose bounded

### Backpressure as a feature

_(Coming in v4.2.0)_

### Memory upper bound is a hard requirement

_(Coming in v4.2.0)_

### CI-friendly determinism

_(Coming in v4.2.0)_

## When to choose unbounded

### When push must always succeed

_(Coming in v4.2.0)_

### Cost: segment allocation on overflow

_(Coming in v4.2.0)_

### Deallocation timing under DEBRA

See [Memory Management](memory-management.md#debra-integration) for the
DEBRA reclamation model.

## Capacity selection (bounded)

### Power-of-2 sizing rationale

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Choosing N: throughput vs memory

_(Coming in v4.2.0)_

For empirical numbers, see [Benchmarks](../benchmarks.md) and
[Performance Tuning](performance-tuning.md#capacity-segment-sizing).

### Multiple producers: contention scaling

_(Coming in v4.2.0)_

## Segment size selection (unbounded)

### Default segment size

_(Coming in v4.2.0)_

### When to override

_(Coming in v4.2.0)_

```nim
# (example coming)
```

## Backpressure patterns

### Spin-and-retry

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Fail-fast (`Option` / `bool` returns)

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Sleep-then-retry

_(Coming in v4.2.0)_

```nim
# (example coming)
```
