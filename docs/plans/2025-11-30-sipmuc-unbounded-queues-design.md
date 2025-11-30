# Sipmuc & Unbounded Queues Design

**Date:** 2025-11-30
**Status:** Approved

## Overview

Add Sipmuc (SPMC) to complete the bounded queue matrix, then create unbounded versions of all four queue types with epoch-based memory reclamation.

### Design Philosophy

- **Bounded queues** = static capacity, static thread counts (predictable, embedded-friendly)
- **Unbounded queues** = dynamic capacity, dynamic thread registration (elastic workloads)

If you need dynamic capacity, you probably need dynamic threads too.

## Type Matrix

### Bounded Queues (Static Everything)

```nim
Sipsic[N: static int, T]                                    # existing - SPSC
Sipmuc[N: static int, C: static int, T]                     # NEW - SPMC
Mupsic[N: static int, P: static int, T]                     # existing - MPSC
Mupmuc[N: static int, P: static int, C: static int, T]      # existing - MPMC
```

### Unbounded Queues (Dynamic Everything)

```nim
UnboundedSipsic[S: static int, T]   # S = segment size, SPSC
UnboundedSipmuc[S: static int, T]   # consumers register dynamically, SPMC
UnboundedMupsic[S: static int, T]   # producers register dynamically, MPSC
UnboundedMupmuc[S: static int, T]   # both register dynamically, MPMC
```

### Performance Guarantees

| Queue | Push | Pop |
|-------|------|-----|
| Sipsic / UnboundedSipsic | Wait-free | Wait-free |
| Sipmuc / UnboundedSipmuc | Wait-free | Lock-free |
| Mupsic / UnboundedMupsic | Lock-free | Wait-free |
| Mupmuc / UnboundedMupmuc | Lock-free | Lock-free |

## Bounded Sipmuc Implementation

### Structure

```nim
type
  Sipmuc*[N: static int, C: static int, T] = object
    # Producer side (single, like Sipsic)
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    storage*: array[N, T]

    # Consumer side (multiple, like Mupmuc)
    consumerHeads*: array[C, Atomic[int]]
    consumerThreadIds*: array[C, Atomic[int]]
    prevConsumerIdx*: Atomic[int]

  Consumer*[N: static int, C: static int, T] = object
    queue: ptr Sipmuc[N, C, T]
    idx: int
```

### Operations

- `push(item: T): bool` — Wait-free, single producer writes to tail
- `getConsumer(): Consumer` — Registers thread, returns consumer handle
- `consumer.pop(): Option[T]` — Lock-free, CAS-based coordination among consumers

### Implementation Approach

- Producer logic from Sipsic (no coordination needed)
- Consumer logic from Mupmuc (CAS on `prevConsumerIdx`)
- Batch operations follow existing patterns

## Epoch-Based Reclamation System

### Core Concept

Threads announce when they're accessing shared memory by "pinning" an epoch. Segments can only be freed when no thread is pinned to the epoch when the segment was retired.

### Structure

```nim
type
  EpochManager* = ref object
    globalEpoch*: Atomic[uint64]
    threadStates*: seq[Atomic[uint64]]  # per-thread pinned epoch (0 = unpinned)
    retireQueue*: seq[tuple[epoch: uint64, segment: pointer]]

  EpochGuard* = object
    manager: EpochManager
    threadIdx: int
    # =destroy unpins automatically
```

### Usage Pattern

```nim
let manager = newEpochManager()
var queue = newUnboundedSipsic[64, int](manager)

# Inside pop (consumer):
let guard = manager.pin()  # pins current epoch
# ... read from segment ...
# guard destroyed, unpins automatically

# Inside segment retirement:
manager.retire(oldSegment)  # adds to retire queue with current epoch
manager.tryReclaim()        # frees segments where all threads have advanced
```

### Key Operations

- `pin(): EpochGuard` — Thread announces it's accessing shared data
- `retire(segment)` — Mark segment for future deallocation
- `tryReclaim()` — Free segments safe to deallocate (called periodically)

## Unbounded Queue Segment Structure

### Segment Layout

```nim
type
  Segment*[S: static int, T] = object
    data*: array[S, T]
    next*: Atomic[ptr Segment[S, T]]  # linked list
    head*: Atomic[int]  # consumer position within segment
    tail*: Atomic[int]  # producer position within segment

  UnboundedSipsic*[S: static int, T] = object
    manager*: EpochManager
    headSegment*: Atomic[ptr Segment[S, T]]  # consumers read from here
    tailSegment*: Atomic[ptr Segment[S, T]]  # producer writes here
    strategy*: DeallocationStrategy
```

### Deallocation Strategies

```nim
type
  DeallocationStrategy* = enum
    NeverDeallocate    # segments stay allocated forever
    EagerDeallocate    # free immediately when empty
    Pooled             # cache N free segments, free excess
```

### Segment Lifecycle

1. Producer fills `tailSegment`
2. When full, producer allocates new segment, links via `next`, advances `tailSegment`
3. Consumer reads from `headSegment`
4. When segment empty and all consumers advanced, retire via `EpochManager`
5. `EpochManager.tryReclaim()` frees when safe (based on strategy)

### Dynamic Thread Registration

- Each producer/consumer registers with queue, gets index
- Per-thread progress tracked to know when segment is truly exhausted
- Registration stored in growable `seq` (no limit)
- Deregistration via `=destroy` hooks (RAII-style)

## API Design

### Bounded API (Existing Pattern)

```nim
var q = Sipmuc[64, 4, int].init()

# Producer (single)
let success: bool = q.push(42)
let unpushed: Option[HSlice] = q.push([1, 2, 3, 4])

# Consumer (must get handle first)
var consumer = q.getConsumer()
let item: Option[int] = consumer.pop()
let items: Option[seq[int]] = consumer.pop(count = 5)
```

### Unbounded API (Different Return Types)

```nim
let manager = newEpochManager()
var q = newUnboundedSipmuc[64, int](manager, Pooled)

# Producer (single) - push always succeeds, returns void
q.push(42)
q.push([1, 2, 3, 4])

# Consumer - registers dynamically, destructor deregisters
var consumer = q.getConsumer()
let item: Option[int] = consumer.pop()
# consumer.`=destroy` called on scope exit

# Unbounded-specific operations
echo q.segmentCount()
q.shrink()  # force reclamation pass
```

### Error Handling

- **Exceptions** for truly exceptional cases (OOM during registration)
- **Option[T]** for expected failures (queue empty)

## Documentation

### Docstring Style (RST/Sphinx)

```nim
proc push*[N, T](self: var Sipsic[N, T], item: T): bool =
  ## Push a single item onto the queue.
  ##
  ## :param item: The item to push onto the queue.
  ## :returns: ``true`` if the item was pushed successfully,
  ##           ``false`` if the queue was full.
  ## :raises: Nothing - this operation is wait-free.
  ##
  ## .. code-block:: nim
  ##    var q = Sipsic[64, int].init()
  ##    assert q.push(42) == true
```

### Mkdocs Site Structure

```
docs/
├── index.md                    # Overview, quick start
├── guide/
│   ├── choosing-a-queue.md     # Decision tree for queue selection
│   ├── bounded-vs-unbounded.md # When to use which
│   ├── segment-size-guide.md   # Guidance on segment sizing
│   └── memory-management.md    # Deallocation strategies explained
├── api/
│   ├── bounded/
│   │   ├── sipsic.md
│   │   ├── sipmuc.md
│   │   ├── mupsic.md
│   │   └── mupmuc.md
│   └── unbounded/
│       ├── epoch-manager.md
│       └── ... (all unbounded types)
└── examples/
    ├── producer-consumer.md
    ├── fan-out.md              # SPMC pattern
    ├── fan-in.md               # MPSC pattern
    └── work-stealing.md        # MPMC pattern
```

### Segment Size Guidance

| Use Case | Recommended Size | Rationale |
|----------|------------------|-----------|
| Small items, high throughput | 256-1024 | Amortize allocation overhead |
| Large items (>1KB) | 16-64 | Avoid memory bloat |
| Low latency | 64-128 | Smaller = faster reclamation |
| Batch processing | 512-2048 | Match batch sizes |

## Implementation Phases

### Phase 1: Bounded Sipmuc

- Implement `Sipmuc[N, C, T]`
- Single-threaded tests
- Multi-threaded stress tests
- Docstrings with examples

### Phase 2: Epoch Manager

- Implement `EpochManager` core
- Pin/unpin/retire/reclaim operations
- Unit tests for reclamation correctness
- Stress tests for concurrent access

### Phase 3: Unbounded Sipsic

- Segment structure
- Integrate with EpochManager
- All three deallocation strategies
- Tests for memory behavior

### Phase 4: Remaining Unbounded Queues

- UnboundedSipmuc (dynamic consumers)
- UnboundedMupsic (dynamic producers)
- UnboundedMupmuc (both dynamic)

### Phase 5: Documentation

- Update all existing docstrings to RST style
- Mkdocs site with guides
- Examples and tutorials

## Files to Create/Modify

### New Files

- `src/lockfreequeues/sipmuc.nim`
- `src/lockfreequeues/epoch.nim`
- `src/lockfreequeues/unbounded/sipsic.nim`
- `src/lockfreequeues/unbounded/sipmuc.nim`
- `src/lockfreequeues/unbounded/mupsic.nim`
- `src/lockfreequeues/unbounded/mupmuc.nim`
- `tests/t_sipmuc.nim`
- `tests/t_sipmuc_threaded.nim`
- `tests/t_epoch.nim`
- `tests/t_unbounded_*.nim`

### Modified Files

- `src/lockfreequeues.nim` (exports)
- `lockfreequeues.nimble` (if needed)
- All existing source files (docstring updates)
