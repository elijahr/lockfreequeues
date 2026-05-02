# API Reference

## Bounded Queues

Fixed-capacity ring buffer implementations. Capacity and thread counts are compile-time constants.

- **[Sipsic](sipsic.md)** - Single-producer, single-consumer (SPSC). Wait-free operations.
- **[Sipmuc](sipmuc.md)** - Single-producer, multiple-consumer (SPMC). Wait-free push, lock-free pop.
- **[Mupsic](mupsic.md)** - Multiple-producer, single-consumer (MPSC). Lock-free push, wait-free pop.
- **[Mupmuc](mupmuc.md)** - Multiple-producer, multiple-consumer (MPMC). Lock-free operations.

## Unbounded Queues

Dynamic-capacity linked segment implementations. Grow as needed with DEBRA+ epoch-based memory reclamation supplied by [nim-debra](https://github.com/elijahr/nim-debra).

- **[UnboundedSipsic](unbounded_sipsic.md)** - Single-producer, single-consumer (SPSC). Wait-free operations.
- **[UnboundedSipmuc](unbounded_sipmuc.md)** - Single-producer, multiple-consumer (SPMC). Wait-free push, lock-free pop.
- **[UnboundedMupsic](unbounded_mupsic.md)** - Multiple-producer, single-consumer (MPSC). Lock-free push, wait-free pop.
- **[UnboundedMupmuc](unbounded_mupmuc.md)** - Multiple-producer, multiple-consumer (MPMC). Lock-free operations.

## Support Types

- **DeallocationStrategy** - Memory reclamation policy:
  - `Manual` - Retire segments to the `DebraManager`. User calls `tryReclaim()` periodically. Best for `--mm:none`.
  - `Eager` - Retire segments and immediately call `tryReclaim()`. Best for GC environments.

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
