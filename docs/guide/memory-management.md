# Memory Management

> Current as of v4.3.0; DEBRA integration patterns may evolve.

How `lockfreequeues` interacts with the memory model, what guarantees the
queues provide vs. what the user must guarantee, the role of cache-line
padding, item-type constraints under ARC / ORC, and the DEBRA epoch-based
reclamation hooks used by the unbounded multi-thread variants.

For the broader thread-safety contract, see [Safety Model](safety-model.md).

## The memory model

### What lockfreequeues guarantees

The queues serialize slot access with C++11-style acquire / release
atomics, so a successful `push` happens-before the matching `pop` in
the modification-order sense. Concretely:

- The slot's data is written before the cursor (`tail` for bounded,
  `seq` counter for the multi-thread bounded variants, `committed` flag
  for the unbounded multi-thread variants) is published with a release
  store.
- The matching consumer reads the cursor with an acquire load, then
  reads the slot's data. The acquire pairs with the producer's release
  to guarantee the consumer sees the fully-initialized slot.
- For the multi-producer / multi-consumer bounded variants, head and
  tail advance via CAS — the CAS-success edge synchronizes claimants.

The pairing is lifted from `debra/atomics`, which `lockfreequeues`
re-exports through `atomic_dsl.nim`. That module exposes the standard
`load`, `store`, `compareExchangeStrong`, `fetchAdd` family plus a
DSL with `loadAcquire` / `storeRelease` shorthand the queue
implementations use throughout.

### What the user must guarantee

The queues do not own the items they carry. If `T` has its own
synchronization requirements — say, a `ptr SharedBuffer` that the
consumer reads through — the user is responsible for ensuring the
buffer's contents are published before the pointer is pushed:

```nim
import lockfreequeues

type Payload = object
  data: array[64, int]

var queue = initSipsic[16, ptr Payload]()

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
tail cross-load dance in `Sipsic`'s push that prevents a producer from
missing a freshly drained slot. Most of the hot path uses the cheaper
acquire / release pair.

## Cache-line padding

### Why fields are padded

Two atomic counters on the same cache line trigger *false sharing*: a
producer thread writing the tail invalidates the consumer thread's
cached copy of the head, and vice versa. On x86_64 a single false-share
event costs tens to hundreds of cycles; on a hot loop, it dominates.

The queue types pin head, tail, and (for the multi-thread variants)
the per-slot sequence array onto separate cache lines using Nim's
`{.align: CacheLineBytes.}` pragma. From `src/lockfreequeues/sipsic.nim`:

```text
type Sipsic*[N: static int, T] = object
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
var queue = newUnboundedSipsic[64, Node]()
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
var q1 = newUnboundedSipsic[64, ptr Node]()

# Index into a shared side-table.
var q2 = newUnboundedSipsic[64, int]()
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

DEBRA is the epoch-based reclamation scheme used by the unbounded
multi-thread variants (`UnboundedSipmuc`, `UnboundedMupsic`,
`UnboundedMupmuc`) to retire and free segments safely under contention.

### What DEBRA solves (epoch-based reclamation)

The problem: a consumer that has just advanced past a segment may still
be reading from it through a stale pointer. Freeing the segment under
that consumer is a use-after-free. DEBRA defers the actual `free` until
every active thread has crossed an epoch boundary, at which point no
thread can possibly be holding a pointer into the retired segment.

The mechanism is invisible at the API level for typical use. Each
multi-thread unbounded queue carries its own `DebraManager`, threads
register and unregister themselves, and reclamation happens implicitly
on `push` and `pop` (Eager strategy) or on demand (Manual strategy).

### Hooks lockfreequeues exposes

The producer / consumer types carry handles that bind a thread to the
queue's manager. Two registration patterns:

```nim
import lockfreequeues

# Auto-register: the queue picks the next available slot and registers
# the calling thread on first use. Sufficient for most cases.
var queue = newUnboundedMupmuc[64, int, 8]()
var producer = queue.getProducer()
var consumer = queue.getConsumer()

producer.push(42)
let item = consumer.pop()
```

Or explicitly, when multiple queues share a manager:

```nim
import debra
import lockfreequeues

var manager = initDebraManager[8]()
var queue = newUnboundedMupmuc[64, int, 8](addr manager)
let producerHandle = registerThread(manager)
let consumerHandle = registerThread(manager)
var producer = queue.getProducer(producerHandle)
var consumer = queue.getConsumer(consumerHandle)
```

The shared-manager pattern matters when you have several queues that
should observe a unified epoch — typically a pipeline where a segment
retired from queue A might still be referenced via queue B.

### When to enable

Reclamation strategy is a compile-time choice via the
`DeallocationStrategy` enum:

- **`Eager`** (default under `--mm:arc`/`orc`/`atomicArc`/`refc`): the
  queue calls DEBRA's reclamation drain automatically every
  `LockFreeQueuesAdvanceEvery` (default 64) pops, via
  `reclaimNow(self.handle)` inside the unbounded MPSC/SPMC/MPMC pop
  paths. The cadence is tunable at compile time with
  `-d:LockFreeQueuesAdvanceEvery=N`. Best for GC environments where
  the extra check is cheap.
- **`Manual`** (default under `--mm:none`): the queue retires segments
  to the manager's limbo bag but does NOT call `tryReclaim` for you.
  The user MUST periodically call `manager.tryReclaim()` (see
  Attribution below) to drain limbo, otherwise retired segments
  accumulate without being freed. Best for `--mm:none` and embedded
  targets where syscall avoidance matters.

Override per queue at construction.

### Attribution: `tryReclaim` is a DEBRA API, not a `lockfreequeues` export

`tryReclaim` is a method on the **DEBRA `Manager`** type (defined in
the `debra` package, not in `lockfreequeues`). Manual-strategy users
call it on their `manager` instance:

```nim
import debra
import lockfreequeues

var manager = initDebraManager[8]()
var queue = newUnboundedMupmuc[64, int, 8](addr manager)
# ... push / pop work ...

# Manual reclamation drain (Manual strategy only — Eager does this
# automatically). Tries to advance the global epoch and free any
# retired-and-now-safe segments.
discard manager.tryReclaim()
```

`lockfreequeues` does NOT re-export `tryReclaim`; importing the queue
module is not enough. Users running under `--mm:none` (or any setup
that selects the `Manual` strategy) must `import debra` to access the
manager API, then call `manager.tryReclaim()` themselves on whatever
cadence fits the workload (the unbounded queues use 64 pops as their
Eager-strategy cadence; that is a sensible starting point for Manual
callers too).

Eager-strategy callers don't need to reach for `tryReclaim` directly —
the queue's pop path calls `reclaimNow(self.handle)` (a thin wrapper
over the manager API) on its own cadence. See `unbounded_sipmuc.nim`,
`unbounded_mupsic.nim`, and `unbounded_mupmuc.nim` pop paths for the
exact call shape; the cadence is gated by
`self.handle.advanceEvery(LockFreeQueuesAdvanceEvery)`.

### Versioning note

DEBRA internals may change; treat the patterns documented here as
current-as-of-v4.3.0. See the
[DEBRA repository](https://github.com/elijahr/nim-debra) for upstream
changes.
