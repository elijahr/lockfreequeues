# API Reference

## Bounded Queues

Fixed-capacity ring buffer implementations. Capacity and thread counts are compile-time constants.

- **[Sipsic](sipsic.md)** - Single-producer, single-consumer. Wait-free operations.
- **[Sipmuc](sipmuc.md)** - Single-producer, multiple-consumer. Wait-free push, lock-free pop.
- **[Mupsic](mupsic.md)** - Multiple-producer, single-consumer. Lock-free push, wait-free pop.
- **[Mupmuc](mupmuc.md)** - Multiple-producer, multiple-consumer. Lock-free operations.

## Unbounded Queues

Dynamic-capacity linked segment implementations. Grow as needed with epoch-based memory reclamation.

- **UnboundedSipsic** - Single-producer, single-consumer. Wait-free operations.
- **UnboundedSipmuc** - Single-producer, multiple-consumer. Wait-free push, lock-free pop.
- **UnboundedMupsic** - Multiple-producer, single-consumer. Lock-free push, wait-free pop.
- **UnboundedMupmuc** - Multiple-producer, multiple-consumer. Lock-free operations.

## Support Types

- **[Ops](ops.md)** - Ring buffer index operations (internal).
- **EpochManager** - Memory reclamation for unbounded queues.
- **DeallocationStrategy** - Memory reclamation policy (NeverDeallocate, EagerDeallocate, Pooled).

## Performance Guarantees

| Guarantee | Meaning |
|-----------|---------|
| Wait-free | Operation completes in bounded steps regardless of other threads |
| Lock-free | At least one thread makes progress; individual threads may retry |

## Segment Size Selection (Unbounded Queues)

| Use Case | Recommended Size | Rationale |
|----------|------------------|-----------|
| Small items, high throughput | 256-1024 | Amortize allocation overhead |
| Large items (>1KB) | 16-64 | Avoid memory bloat |
| Low latency | 64-128 | Smaller = faster reclamation |
| Batch processing | 512-2048 | Match batch sizes |

Segment size should be a power of 2 and ideally a multiple of cache line size (64 bytes on most systems).

## Cache Line Considerations

### Bounded Queues

The bounded queues use cache line alignment for head/tail pointers to prevent false sharing. Capacity should be chosen to avoid unnecessary padding:

- **Good**: 16, 32, 64, 128, 256 (power of 2)
- **Avoid**: Arbitrary values that don't align well

### Unbounded Queues

Segment size affects memory layout. Larger segments mean fewer allocations but slower reclamation. Consider:

- Each segment has fixed overhead (~64 bytes for metadata)
- Item count per segment = segment size parameter
- Total segment memory = (segment size × item size) + overhead
