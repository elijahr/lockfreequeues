# Performance Tuning

Practical guidance for getting the most out of `lockfreequeues`: how to size
capacity (or segments), where to place producer and consumer threads, how
batch sizing changes amortized cost, and which compile-time settings matter.

For the published benchmark numbers and methodology, see
[Benchmarks](../benchmarks.md).

## Capacity / segment sizing

### Throughput-vs-memory trade-off

_(Coming in v4.2.0)_

### Empirical data

See [Benchmarks](../benchmarks.md) for the measured throughput-vs-capacity
curves and the reproducer commands used to generate them.

For the conceptual rationale, see
[Bounded vs Unbounded → Choosing N](bounded-vs-unbounded.md#choosing-n-throughput-vs-memory).

## Thread placement

### NUMA awareness (or lack thereof)

_(Coming in v4.2.0)_

### Pinning producers and consumers separately

_(Coming in v4.2.0)_

```nim
# (example coming)
```

## Batch sizing

### Per-call vs amortized cost

_(Coming in v4.2.0)_

### Measured impact in `bench_*.nim` overrides

See [Benchmarks](../benchmarks.md) for the bench harness configuration and
batch-size sweeps.

```nim
# (example coming)
```

## Compile-time settings

### `-d:release` vs `-d:danger`

_(Coming in v4.2.0)_

### Sanitiser combos and their cost

_(Coming in v4.2.0)_

### MM choice (`orc` / `arc` / `atomicArc`)

For the safety implications of each memory manager choice, see
[Safety Model → Test matrix](safety-model.md#test-matrix) and
[Memory Management → Item types and ARC / ORC](memory-management.md#item-types-and-arc-orc).

## Methodology link

See [Benchmarks](../benchmarks.md) for the methodology that produced the
published numbers, including reproducer commands and CI tuning overrides.
