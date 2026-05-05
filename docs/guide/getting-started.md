# Getting Started

Your first five minutes with `lockfreequeues`: install the library, build a
single-producer / single-consumer queue, push and pop a value, and learn the
two or three pitfalls that catch most newcomers.

If you are evaluating whether to use this library at all, jump first to
[Core Concepts](core-concepts.md) and
[Bounded vs Unbounded](bounded-vs-unbounded.md).

## Install

### Via nimble

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Pinning a version

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Verifying the install

_(Coming in v4.2.0)_

```nim
# (example coming)
```

## Your first SPSC queue

The smallest useful program: one producer, one consumer, one bounded queue.

### A 10-line "push and pop" example

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### Running with `--threads:on`

_(Coming in v4.2.0)_

```nim
# (example coming)
```

### What to expect on success

_(Coming in v4.2.0)_

## Common pitfalls

The three errors that account for the majority of "it doesn't compile" or
"it deadlocks immediately" reports.

### "Item type is not lock-free safe"

See [Memory Management](memory-management.md) for the full story on item
type requirements.

### Power-of-2 capacity vs arbitrary N

See [Bounded vs Unbounded](bounded-vs-unbounded.md#capacity-selection-bounded)
for the full rationale.

### Forgetting `--threads:on`

_(Coming in v4.2.0)_

## Next steps

### Multi-producer / multi-consumer variants

See [Core Concepts](core-concepts.md) for the SPSC / SPMC / MPSC / MPMC
quadrant and which queue type fits which pattern.

### Bounded vs Unbounded

See [Bounded vs Unbounded](bounded-vs-unbounded.md) for the decision guide.

### Performance tuning

See [Performance Tuning](performance-tuning.md) for capacity sizing,
thread placement, and compile-time settings.
