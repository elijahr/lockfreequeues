# Memory Management

> Current as of v5.0.0; reflects the shipped live-EBR attach model.

How `lockfreequeues` interacts with the memory model, what guarantees the
queues provide vs. what the user must guarantee, the role of cache-line
padding, item-type constraints under ARC / ORC, and the DEBRA epoch-based
reclamation hooks used by the multi-cardinality unbounded shapes.

In v5.0.0 the reclamation model is cardinality-driven: single-cardinality
arms (both ends `ccSingle`) are debra-free, while any arm with a multi
producer or multi consumer is wired to live epoch-based reclamation (EBR)
via DEBRA. Multi-cardinality views register with the queue's epoch
manager at *attach time* on their operating thread, and the unbounded
`Queue` is non-copyable (its `=copy` hook is `{.error.}`-gated) because it
owns a segment chain and a `ptr DebraManager`.

For the broader thread-safety contract, see [Safety Model](safety-model.md).

## The memory model

### What lockfreequeues guarantees

The queues serialize slot access with C++11-style acquire / release
atomics, so a successful `push` happens-before the matching `pop` in
the modification-order sense. Concretely:

- The slot's data is written before the cursor (`tail` for the bounded
  SPSC shape, `seq` counter for the multi-cardinality bounded shapes,
  `committed` flag for the multi-cardinality unbounded shapes) is
  published with a release store.
- The matching consumer reads the cursor with an acquire load, then
  reads the slot's data. The acquire pairs with the producer's release
  to guarantee the consumer sees the fully-initialized slot.
- For the multi-producer / multi-consumer bounded shapes, head and
  tail advance via CAS — the CAS-success edge synchronizes claimants.

The pairing is lifted from `debra/atomics`, which `lockfreequeues`
re-exports directly (alongside `debra/atomics/dsl`) from the umbrella
module. Those modules expose the standard `load`, `store`,
`compareExchangeStrong`, `fetchAdd` family plus a DSL with
`loadAcquire` / `storeRelease` shorthand the queue implementations use
throughout.

### What the user must guarantee

The queues do not own the items they carry. If `T` has its own
synchronization requirements — say, a `ptr SharedBuffer` that the
consumer reads through — the user is responsible for ensuring the
buffer's contents are published before the pointer is pushed:

```nim
import lockfreequeues

type Payload = object
  data: array[64, int]

var queue = newSpscQueue[ptr Payload, 16]()

# WRONG: consumer might read uninitialized data through the pointer.
# proc badProducer(slot: ptr Payload, value: int) =
#   discard queue.push(slot)  # publish before write — race!
#   slot.data[0] = value

# CORRECT: write the payload first, push the pointer second. The
# release in `push` makes the prior writes visible to the consumer.
proc producer(slot: ptr Payload, value: int) =
  slot.data[0] = value
  discard queue.push(slot)
```

The release-on-publish in `push` is what makes the ordering work — the
consumer's acquire-on-`pop` synchronizes with the producer's most recent
release, including the writes that preceded it.

### Acquire / release ordering, in plain English

Acquire / release is the weakest pairwise ordering that still allows the
"write data, then publish" idiom. It says nothing about ordering between
unrelated stores; it only links the specific acquire that observes a
specific release.

A practical mental model:

- A **release store** is a one-way wall: prior writes in the storing
  thread cannot move past it.
- An **acquire load** is the matching one-way wall: subsequent reads in
  the loading thread cannot move before it.
- Together, they guarantee that everything the producer wrote before
  the release is visible to the consumer after the matching acquire.

`lockfreequeues` uses sequential-consistency (`moSequential`) only where
the protocol genuinely needs total ordering — for example, the head /
tail cross-load dance in the SPSC push that prevents a producer from
missing a freshly drained slot. Most of the hot path uses the cheaper
acquire / release pair.

## Cache-line padding

### Why fields are padded

Two atomic counters on the same cache line trigger *false sharing*: a
producer thread writing the tail invalidates the consumer thread's
cached copy of the head, and vice versa. On x86_64 a single false-share
event costs tens to hundreds of cycles; on a hot loop, it dominates.

The queue types pin head, tail, and (for the multi-cardinality shapes)
the per-slot sequence array onto separate cache lines using Nim's
`{.align: CacheLineBytes.}` pragma. From the SPSC body of
`BQueue` in `src/lockfreequeues/bqueue.nim`:

```text
type BQueue*[T; ccProd, ccCons: static PinScopeCardinality,
             N, P, C: static int] = object
  # SPSC body (ccProd == ccCons == ccSingle):
  head* {.align: CacheLineBytes.}: Atomic[int]
  tail* {.align: CacheLineBytes.}: Atomic[int]
  storage*: StorageN1[N, T]
```

`CacheLineBytes` comes from `debra/atomics` and resolves to 128 on
PowerPC (where lines are double-width) and 64 elsewhere. Override at
compile time with `-d:CacheLineBytes=N` if you are targeting a platform
the default does not match.

### How padding interacts with sanitisers

ThreadSanitizer is sensitive to false sharing — not because the program
is wrong, but because TSAN's shadow memory tracks accesses at byte
granularity and can over-report on tightly packed atomics. The queue's
explicit padding sidesteps the over-reporting entirely: head and tail
are guaranteed to live on different lines, so TSAN sees them as
independent.

AddressSanitizer is unaffected by padding. ASAN tracks allocations and
out-of-bounds, both of which are orthogonal to the padding question.

### Auditing your own types

If your item type is large enough that two adjacent slots cross a
cache line, bumping it to a multiple of `CacheLineBytes` is sometimes
worth it — but only when the workload is contention-bound. For most
cases the queue's own padding is sufficient, and per-item padding
wastes memory.

The check is mechanical:

```nim
import lockfreequeues

type SmallPayload = object
  value: int  # 8 bytes
  flag: bool  # 1 byte; with padding, 16 total

static:
  doAssert sizeof(SmallPayload) == 16
  # 16 fits 4 per 64-byte line — fine for low contention, suspect for high.
```

If profiling shows the slot store is the contention point, consider
bumping the item to a full cache line. Nim's `{.align.}` pragma applies
to fields, so the idiomatic pattern is to align the first field and
pad the rest:

```nim
import lockfreequeues  # for CacheLineBytes (re-exported from debra/atomics)

type PaddedPayload = object
  value {.align: CacheLineBytes.}: int
  flag: bool
  pad: array[CacheLineBytes - sizeof(int) - sizeof(bool), byte]
```

The first field's alignment forces the object onto a cache-line boundary;
the trailing `pad` array fills the line so the next slot in a contiguous
array also lands on its own line.

## Item types and ARC / ORC

The default policy: queue item types must be lock-free. See
[Safety Model](safety-model.md#item-type-requirements) for the full
contract.

### `ref T` is rejected by default

Under `--mm:arc`, `--mm:orc`, or `--mm:atomicArc`, the queue rejects
`ref` item types at compile time:

```text
import lockfreequeues

type Node = ref object
  value: int

# Compile error under arc/orc/atomicArc with default settings:
#   "Queue item type 'Node' is a ref type. Slots are stored in a shared
#    array; `=copy`/`=sink` hooks mutate the refcount on the same object
#    multiple threads can read or write..."
var queue = newUnboundedSpscQueue[Node, stEager, 64, 4]()
```

### Why the rejection is a feature

The error wording above is the long version; the short version: a `ref`
in a slot has its refcount mutated by `=copy` and `=sink` hooks, and
those hooks run on whichever thread happens to push or pop. Two threads
mutating the same refcount is a race regardless of whether the refcount
itself uses atomics — `atomicArc` makes the refcount atomic but not the
hook calls themselves.

The right pattern under arc/orc is a `ptr T` slot with manual lifetime,
or a value-type slot, or an integer index into a side-table the
consumer dereferences:

```nim
import lockfreequeues

type Node = object
  value: int

# Pointer to a heap-allocated Node, lifetime managed by the producer.
var q1 = newUnboundedSpscQueue[ptr Node, stEager, 64, 4]()

# Index into a shared side-table.
var q2 = newUnboundedSpscQueue[int, stEager, 64, 4]()
```

### `-d:allowNonLockFreeQueueItems` escape hatch

If you understand the trade-offs and need `ref` items anyway:

```sh
nim c -d:allowNonLockFreeQueueItems --threads:on myprog.nim
```

The flag opts out of the static check. It does not make `ref` items
safe — it asserts you have done the analysis and accept the consequences
on your platform. The recommended use case is "I have measured this
workload on the target platform and confirmed the refcount path uses
genuinely lock-free atomics". For everything else, prefer `ptr T`.

## DEBRA integration

DEBRA ([Brown 2015](https://www.cs.utoronto.ca/~tabrown/debra/)) is the
epoch-based reclamation (EBR) scheme used by the
multi-cardinality unbounded shapes (any unbounded `Queue` with a multi
producer or multi consumer — MPSC, SPMC, MPMC) to retire and free
segments safely under contention. The single-cardinality unbounded shape
(SPSC, `newUnboundedSpscQueue`) is debra-free: it owns no
`DebraManager` and reclaims segments directly.

### What DEBRA solves (epoch-based reclamation)

The problem: a consumer that has just advanced past a segment may still
be reading from it through a stale pointer. Freeing the segment under
that consumer is a use-after-free. DEBRA defers the actual `free` until
every active thread has crossed an epoch boundary, at which point no
thread can possibly be holding a pointer into the retired segment.

The mechanism is invisible on the hot path once threads are registered.
Each multi-cardinality unbounded queue carries its own `DebraManager`,
each operating thread registers itself once (at *attach time*), and
reclamation happens implicitly on `push` and `pop` (`stEager` strategy)
or on demand (`stManual` strategy).

### Attach-time registration

The v5.0.0 registration model is thread-affine: no thread is registered
at construction. Each multi-cardinality view registers the *calling*
thread with the queue's `DebraManager` on its first use, via `attach()`.
The single consumer of an unbounded MPSC queue uses `attachConsumer()` on
its own consuming thread instead. Registration MUST happen on the thread
that will subsequently `push()` / `pop()` through the view. Two failure
modes are distinct: if the manager's `MaxThreads` slots are exhausted,
`attach()` / `attachConsumer()` raise `DebraRegistrationError`. Cross-thread
misuse — registering on one thread and operating from another — fires a
debug-only assert in debug builds and silently corrupts reclamation in
release builds, so size `MaxThreads` correctly and keep each view's
`attach()` and `push()` / `pop()` on the same thread.

```nim
import options
import lockfreequeues

# Auto-create: the queue owns its DebraManager. `stEager` strategy,
# segment size 64, debra registry capacity 8.
var queue = newUnboundedMpmcQueue[int, stEager, 64, 8]()

# On the producer thread:
var producer = queue.getProducer()
producer.attach()       # register THIS thread before the first push
producer.push(42)

# On the consumer thread:
var consumer = queue.getConsumer()
consumer.attach()       # register THIS thread before the first pop
let item = consumer.pop()
```

For an unbounded MPSC queue the single consumer attaches through the
queue directly:

```nim
import options
import lockfreequeues

var queue = newUnboundedMpscQueue[int, stEager, 64, 8]()

# Single consumer registers on its own thread:
queue.attachConsumer()

# Each producer thread attaches its own view:
var producer = queue.getProducer()
producer.attach()
producer.push(7)
let item = queue.pop()
```

### Slot accounting and the non-copyable contract

Each `attach()` consumes one `MaxThreads` registration slot for the
lifetime of the owned `DebraManager` (DEBRA 0.8.0 has no per-thread
unregister; `detach()` does not free the slot). Size `MaxThreads` for the
total number of *distinct* threads that will ever operate the queue, not
the peak concurrent count.

Because a multi-cardinality `Queue` owns a `ptr Segment` chain and a
`ptr DebraManager`, it is non-copyable: its `=copy` hook is
`{.error.}`-gated to prevent aliasing the owned pointers (which would
double-free at `=destroy`). Move the `Queue`, or share it by `ptr` / `var`
parameter into thread procs.

### Borrowing an external manager

When several queues should observe a unified epoch — typically a pipeline
where a segment retired from queue A might still be referenced via queue
B — construct the queue against an externally owned `DebraManager`:

```nim
import lockfreequeues
from debra import DebraManager, initDebraManager

# Manager owned by the caller; the queue borrows it (ownsManager = false).
var manager = initDebraManager[8, debra.ccMulti]()
var queue = newUnboundedMpmcQueue[int, stEager, 64, 8](addr manager)
var producer = queue.getProducer()
producer.attach()
producer.push(1)
```

### When to enable each strategy

Reclamation strategy is a compile-time choice via the `ST` (deallocation
strategy) generic parameter: `stEager` reclaims after segment retirement
(best for GC environments where the extra check is cheap); `stManual`
retires only, deferring the actual reclamation (best for `--mm:none` and
embedded targets where reclamation timing must be controlled).

### Versioning note

DEBRA internals may change; treat the patterns documented here as
current-as-of-v5.0.0. See the
[DEBRA repository](https://github.com/elijahr/nim-debra) for upstream
changes.
