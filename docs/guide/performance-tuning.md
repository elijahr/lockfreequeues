# Performance Tuning

Practical guidance for getting the most out of `lockfreequeues`: how to size
capacity (or segments), where to place producer and consumer threads, how
batch sizing changes amortized cost, and which compile-time settings matter.

For the published benchmark numbers and methodology, see
[Benchmarks](../benchmarks.md).

## Capacity / segment sizing

### Throughput-vs-memory trade-off

Capacity is the single biggest knob on bounded throughput. Too small and
the producer spends time on rejected pushes; too large and you blow the
memory budget for nothing. The sweet spot depends on the producer's
burst profile: pick `N` such that the 99th-percentile burst fits, plus
25-50% slack so a sudden 95th-percentile event does not push you over
the edge.

For unbounded queues, `S` (segment size) plays the same role at a
smaller granularity. Each segment fill triggers one `aligned_alloc`
plus a release store to publish the next pointer. At 10 M items/s and
`S = 64`, you allocate 156k segments per second — fine on a fast malloc,
visible on a slow one. At `S = 4096`, the same workload allocates 2400
segments per second, which is well below any reasonable malloc's noise
floor.

A reasonable starting trio:

```nim
import lockfreequeues

# Audio frame queue: 64 samples × 4 bytes = 256 B; 1 cache line of slack.
var audio = newSpscQueue[float32, 64]()

# HTTP request fan-in: segment size 256, debra registry capacity 16.
var requests = newUnboundedMpscQueue[int, stEager, 256, 16]()

# Sustained event ingest: large segments amortize alloc.
var events = newUnboundedMpmcQueue[int, stEager, 1024, 8]()
```

### Empirical data

See [Benchmarks](../benchmarks.md) for the measured throughput-vs-capacity
curves and the reproducer commands used to generate them.

For the conceptual rationale, see
[Bounded vs Unbounded → Choosing N](bounded-vs-unbounded.md#choosing-n-throughput-vs-memory).

## Thread placement

### NUMA awareness (or lack thereof)

`lockfreequeues` is NUMA-naïve. The library does no remote-vs-local
detection, no per-socket queue partitioning, no first-touch allocation.
A queue allocated by thread A on socket 0 lives on socket 0 forever; a
consumer running on socket 1 pays a remote-memory penalty on every
slot read.

For single-socket machines this does not matter. For dual-socket and
larger, the right pattern is to keep producers and consumers of a given
queue on the same socket. Two queues, one per socket, with a slow path
between them, is usually faster than one queue spanning both. Measure
before assuming — modern interconnects (UPI on Intel, Infinity Fabric
on AMD) can hide a lot of remote-access cost.

### Pinning producers and consumers separately

The general rule: producer and consumer of the same queue belong on
*different* physical cores, but the *same* socket / NUMA node. Sharing
a hyperthread sibling with the other side of the queue costs more than
running on a different physical core, because the two ends of the queue
contend for the same core's L1.

Nim's stdlib does not expose `pthread_setaffinity_np` directly, but the
`std/posix` module imports it on POSIX targets. A typical setup wraps
the FFI in a small helper:

```nim
when defined(linux):
  proc pinThreadToCore(coreId: int) =
    # Sketch: in production you would import from std/posix and
    # populate a cpu_set_t. Stay framework-agnostic in your own code.
    discard coreId
```

Concrete numbers from a workstation we benchmarked: an SPSC queue with
producer and consumer on hyperthread siblings ran ~25% slower than the
same queue with the two ends on different physical cores. The
difference grows under contention.

## Batch sizing

### Per-call vs amortized cost

Every `push` and `pop` pays a fixed per-call overhead: load the cursor
with acquire, compute the next index, release-store the cursor back.
For an SPSC queue at peak throughput, that overhead is 30-60 ns per
call on x86_64. If you have 1000 items to publish and you call `push`
1000 times, you pay the overhead 1000 times.

The bounded queues expose batch overloads that take an `openArray[T]`
on the producer side and an integer count on the consumer side:

```nim
import options
import lockfreequeues

var queue = newSpscQueue[int, 256]()
let items = @[1, 2, 3, 4, 5, 6, 7, 8]

# Single batch push — one cursor advance for the whole batch.
let rejected = queue.push(items)
if rejected.isSome:
  echo "queue rejected slice ", rejected.get

# Batch pop — one cursor advance to drain up to 8 items.
let drained = queue.pop(8)
if drained.isSome:
  for v in drained.get:
    echo v
```

The amortized per-item cost in the batch path is roughly
`(per-call overhead) / batch_size + per-item write/read`. At
`batch_size = 8` you cut the cursor-management overhead by 8×; at
`batch_size = 64`, by 64× — at which point the per-item slot store
dominates and further batching stops helping.

### Measured impact in `bench_*.nim` overrides

See [Benchmarks](../benchmarks.md) for the bench harness configuration and
batch-size sweeps. The bench harness exposes per-shape overrides so you
can probe a specific (producer-count, consumer-count, batch-size) cell
without re-running the whole sweep.

If your queue shape does not expose batch overloads (for example, the
multi-cardinality unbounded shapes), batch at the application layer:
collect a small slice, publish it under a single producer mutex (or a
per-thread staging buffer), and amortize the per-call cost outside the
queue.

## Compile-time settings

### `-d:release` vs `-d:danger`

The default debug build keeps every runtime check Nim emits: bounds,
nil dereferences, integer overflow. That overhead is enormous for the
queues, where the hot path is half a dozen atomic operations and a
slot write.

```sh
# Debug: every check enabled. Safe, slow.
nim c --threads:on myprog.nim

# Release: optimisations on, runtime checks for arithmetic still on.
nim c --threads:on -d:release myprog.nim

# Danger: bounds checks off, overflow checks off. Fastest, least forgiving.
nim c --threads:on -d:danger myprog.nim
```

The benchmarks ship under `-d:release`. For application code the choice
is usually `-d:release` — the bounds check on a slot store is cheap
enough that turning it off rarely pays for the loss of safety. Reach
for `-d:danger` only when profiling has identified a specific check as
the bottleneck and you have audited that the check is provably
unnecessary.

### Sanitiser combos and their cost

ThreadSanitizer and AddressSanitizer dramatically change the cost
model. TSAN slows the queue ~5-10× and inflates memory ~2-3×; ASAN
~2× speed and ~3× memory. Both are essential during testing and
catastrophic in production. The CI matrix runs both
(see [Safety Model → Test matrix](safety-model.md#test-matrix)) under
`atomicArc` (TSAN) and the default MM (ASAN).

For local performance work, run without sanitisers; turn them on
separately to confirm the result is also clean under sanitiser.

### MM choice (`orc` / `arc` / `atomicArc`)

The Nim memory manager affects two things: how `ref` items are
managed (relevant only when you have opted into them with
`-d:allowNonLockFreeQueueItems`), and how `string` / `seq` move
through the queue if you happen to be using them as items.

For lock-free correctness, `arc` and `orc` are equivalent on the
queues' own state — both are lock-free for the queues' own atomics.
`atomicArc` is required when a `ref` item under `--mm:arc` would
fall back to non-atomic refcounting; on platforms where it would not,
`atomicArc` adds cost without adding safety.

Nim 2.2.0 or newer is required (see `lockfreequeues.nimble`'s `requires`
line). Older Nim toolchains miss some of the atomic builtins the queues
rely on.

For the safety implications of each memory manager choice, see
[Safety Model → Test matrix](safety-model.md#test-matrix) and
[Memory Management → Item types and ARC / ORC](memory-management.md#item-types-and-arc-orc).

## Methodology link

See [Benchmarks](../benchmarks.md) for the methodology that produced the
published numbers, including reproducer commands and CI tuning overrides.
