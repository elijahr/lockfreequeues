# Migrating to lockfreequeues 5.0.0

lockfreequeues 5.0.0 is a **SemVer MAJOR** release. The eight per-family
queue type names from the 4.1.x line collapse to **two** unified generic
types:

- `BQueue[T, ccProd, ccCons, N, P, C]` — the bounded ring buffer
  (absorbs `Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`).
- `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` — the unbounded
  linked-segment queue (absorbs `UnboundedSipsic`, `UnboundedSipmuc`,
  `UnboundedMupsic`, `UnboundedMupmuc`). The `(ccSingle, ccSingle)` arm
  absorbs the formerly standalone `UnboundedSipsic` body verbatim and
  stays debra-free.

The `ccProd` / `ccCons` parameters (`ccSingle` / `ccMulti`) select the
producer and consumer cardinality.

**No type aliases are provided.** Every typed call site (`var q: Mupsic[...]`,
`var u: UnboundedMupmuc[...]`, etc.) must migrate to the `BQueue[T, ...]`
or `Queue[T, ...]` form. The migration is mechanical but pervasive: a
typical 4.1.x adopter touches every `import lockfreequeues` call site.
For ergonomic continuity, each cell of the SPSC/SPMC/MPSC/MPMC grid keeps
a **family-named smart constructor** (`newSipsicQueue`, `newMupmucQueue`,
`newUnboundedMupmucQueue`, …) — these are thin wrappers over the two
generic constructors `newBQueue` / `newQueue`, so most call-site churn is
the constructor name and the parameter order, not a hand-rolled generic.

> **Unbounded path dependency.** The unbounded `Queue` cardinalities
> other than `(ccSingle, ccSingle)` integrate `nim-debra` for
> epoch-based reclamation and require `nim-debra >= 0.8.0` (the
> coordinated release wave: `typestates 0.9.0` → `nim-debra 0.8.0` →
> `lockfreequeues 5.0.0`). The bounded `BQueue` families have no debra
> integration and migrate immediately. The unbounded SPSC arm
> (`newUnboundedSipsicQueue`) is also debra-free.

## What changed

- **Removed public types**: `Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`,
  `UnboundedSipsic`, `UnboundedSipmuc`, `UnboundedMupsic`,
  `UnboundedMupmuc`. Replaced by `BQueue[T, ccProd, ccCons, N, P, C]`
  (bounded) and `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
  (unbounded).
- **Removed public constructors**: `initSipsic`, `initSipmuc`,
  `initMupsic`, `initMupmuc`, `newUnboundedSipsic`, `newUnboundedSipmuc`,
  `newUnboundedMupsic`, `newUnboundedMupmuc`. Replaced by the two generic
  constructors `newBQueue[T, ...]()` (bounded) and `newQueue[T, ...]()`
  (unbounded), plus the family-named wrappers `newSipsicQueue` /
  `newMupsicQueue` / `newSipmucQueue` / `newMupmucQueue` (bounded) and
  `newUnboundedSipsicQueue` / `newUnboundedSipmucQueue` /
  `newUnboundedMupsicQueue` / `newUnboundedMupmucQueue` (unbounded).
- **`DeallocationStrategy` is now a static type parameter** `ST` on the
  unbounded `Queue`. The runtime `strategy:` field on the legacy
  `Unbounded*` queues is removed; every `if self.strategy == X` collapses
  to `when ST == X`, and `stManual` vs `stEager` monomorphize separately.
  `ST` defaults to `DefaultDeallocationStrategy` on the constructors.
  Bounded `BQueue` carries no `ST` axis.
- **Cardinality is now exposed as static phantoms** `ccProd, ccCons` on
  both `BQueue` and `Queue` (and is threaded through
  `ThreadHandle[MaxThreads, CC]` on the unbounded queue's debra fields and
  the producer/consumer views).
- **No defaults** for `ccProd` / `ccCons`. The unification's purpose is to
  make cardinality explicit at the call site; defaults would re-introduce
  the implicit-cardinality ambiguity it eliminates. (The family-named
  smart constructors pre-bind the cardinality for you.)
- **`Queue` is non-copyable.** The unbounded `Queue` owns a heap
  `ptr Segment` chain and, for the debra-integrated cardinalities, a
  `ptr DebraManager`; its `=copy` hook is a compile-time error. Move it,
  or share it by `ptr` / `var` parameter into worker threads. `BQueue`
  remains copyable (it owns only inline slot storage).

## Migration table

Every removed public symbol and its unified 5.0.0 replacement. This table
is the authoritative reference for mechanical sed of an existing
4.1.x codebase.

### Type declarations

Bounded families map to `BQueue[T, ccProd, ccCons, N, P, C]`; unbounded
families map to `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`. For the
bounded families the per-side registry capacities `P` (producers) and `C`
(consumers) are `0` on the single-cardinality side.

| Before (4.1.x) | After (5.0.0) |
|---|---|
| `type X = Sipsic[N, T]` | `type X = BQueue[T, ccSingle, ccSingle, N, 0, 0]` |
| `type X = Sipmuc[N, C, T]` | `type X = BQueue[T, ccSingle, ccMulti, N, 0, C]` |
| `type X = Mupsic[N, P, T]` | `type X = BQueue[T, ccMulti, ccSingle, N, P, 0]` |
| `type X = Mupmuc[N, P, C, T]` | `type X = BQueue[T, ccMulti, ccMulti, N, P, C]` |
| `type X = UnboundedSipsic[S, T]` | `type X = Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]` |
| `type X = UnboundedSipmuc[S, T, MaxThreads]` | `type X = Queue[T, ccSingle, ccMulti, stEager, S, MaxThreads]` |
| `type X = UnboundedMupsic[S, T, MaxThreads]` | `type X = Queue[T, ccMulti, ccSingle, stEager, S, MaxThreads]` |
| `type X = UnboundedMupmuc[S, T, MaxThreads]` | `type X = Queue[T, ccMulti, ccMulti, stEager, S, MaxThreads]` |

> Note the unbounded `UnboundedSipsic[S, T]` gains a `MaxThreads`
> parameter under the unified `Queue` type even though the absorbed
> `(ccSingle, ccSingle)` arm is debra-free and never touches the
> registry. Pass any positive `MaxThreads` (the family-named
> `newUnboundedSipsicQueue` smart constructor makes this explicit).

### Constructor call sites

The two generic constructors are `newBQueue` (bounded) and `newQueue`
(unbounded). The family-named smart constructors below pre-bind the
cardinality and are the recommended, lowest-churn target.

| Before (4.1.x) | After (5.0.0) |
|---|---|
| `var q = initSipsic[N, T]()` | `var q = newSipsicQueue[T, N]()` |
| `var q = initSipmuc[N, C, T]()` | `var q = newSipmucQueue[T, N, C]()` |
| `var q = initMupsic[N, P, T]()` | `var q = newMupsicQueue[T, N, P]()` |
| `var q = initMupmuc[N, P, C, T]()` | `var q = newMupmucQueue[T, N, P, C]()` |
| `var q = newUnboundedSipsic[S, T]()` | `var q = newUnboundedSipsicQueue[T, stEager, S, MaxThreads]()` |
| `var q = newUnboundedSipmuc[S, T, MaxThreads](addr m)` | `var q = newUnboundedSipmucQueue[T, stEager, S, MaxThreads](addr m)` |
| `var q = newUnboundedMupsic[S, T, MaxThreads](addr m, h)` | `var q = newUnboundedMupsicQueue[T, stEager, S, MaxThreads](addr m, h)` |
| `var q = newUnboundedMupsic[S, T, MaxThreads](addr m, h, Manual)` | `var q = newUnboundedMupsicQueue[T, stManual, S, MaxThreads](addr m, h)` |
| `var q = newUnboundedMupmuc[S, T, MaxThreads](addr m)` | `var q = newUnboundedMupmucQueue[T, stEager, S, MaxThreads](addr m)` |

> Equivalently, write the generic constructors directly:
> `newBQueue[T, ccMulti, ccMulti, N, P, C]()` for the bounded shapes and
> `newQueue(Queue[T, ccMulti, ccMulti, stEager, S, MaxThreads], addr m)`
> for the unbounded borrow forms. The family-named wrappers expand to
> exactly these.

> In v5, `ST` defaults to `DefaultDeallocationStrategy` (which is
> `stEager` when GC is enabled, `stManual` under `--mm:none`). The tables
> above show `stEager` explicitly for fidelity to the v4 default; in new
> code you may omit `ST` from smart-constructor calls and let the default
> apply (e.g., `newUnboundedSipsicQueue[T, S, MaxThreads]()`).

> The runtime `strategy:` argument that previously sat on
> `newUnboundedMupsic` / `newUnboundedSipmuc` / `newUnboundedMupmuc` is
> **gone**. To select `stManual` vs `stEager`, write the desired strategy
> directly in the `ST` generic position (e.g., the `stManual` row above).
> Each unbounded family also exposes a manager-borrow overload taking
> `addr manager` and an auto-create overload taking no manager argument
> (it allocates a private `DebraManager`).

## Worked examples

The migration below shows each legacy family translated into its v5.0.0
shape, including a typical use that exercises the constructor and one
push/pop.

### Bounded — `Mupsic` (multi-producer / single-consumer)

```nim
import options
import lockfreequeues

# Before (4.1.x)
# var q = initMupsic[16, 4, int]()

# After (5.0.0): newMupsicQueue[T, N, P] — N capacity, P producer slots.
var q = newMupsicQueue[int, 16, 4]()
var p = q.getProducer()
discard p.push(42)
let v = q.pop()
assert v == some(42)
```

### Bounded — `Sipmuc` (single-producer / multi-consumer)

```nim
import lockfreequeues

# Before
# var q = initSipmuc[16, 4, int]()

# After: newSipmucQueue[T, N, C] — N capacity, C consumer slots.
var q = newSipmucQueue[int, 16, 4]()
```

### Bounded — `Mupmuc` (multi-producer / multi-consumer)

```nim
import lockfreequeues

# Before
# var q = initMupmuc[16, 4, 4, int]()

# After: newMupmucQueue[T, N, P, C].
var q = newMupmucQueue[int, 16, 4, 4]()
```

### Bounded — `Sipsic` (single-producer / single-consumer)

```nim
import options
import lockfreequeues

# Before
# var q = initSipsic[16, int]()

# After: newSipsicQueue[T, N]. Single-cardinality sides push/pop directly.
var q = newSipsicQueue[int, 16]()
discard q.push(42)
let v = q.pop()
assert v == some(42)
```

### Unbounded — `UnboundedMupsic`

The unbounded families take `[T, ST, S, MaxThreads]` (deallocation
strategy, segment size, debra registry capacity). They expose three
overloads: auto-create (no manager argument — allocates a private
`DebraManager`), manager-borrow (`addr manager`), and the manager-borrow
escape hatch that also accepts a pre-registered consumer handle.

```nim
import lockfreequeues
from debra import DebraManager, initDebraManager, registerThread

# Before (4.1.x)
# var mgr = initDebraManager[4]()
# let h = registerThread(mgr)
# var q = newUnboundedMupsic[16, int, 4](addr mgr, h)
# stEager was the runtime default; for Manual, the field was passed:
# var q = newUnboundedMupsic[16, int, 4](addr mgr, h, Manual)

# After (5.0.0): manager-borrow + pre-registered consumer handle.
# The handle's cardinality binds from the manager (ccSingle here).
var mgr = initDebraManager[4, debra.ccSingle]()
let h = registerThread(mgr)
var q = newUnboundedMupsicQueue[int, stEager, 16, 4](addr mgr, h)
# For Manual: choose the ST generic at the call site.
# var q = newUnboundedMupsicQueue[int, stManual, 16, 4](addr mgr, h)
```

Most code does not need to register the consumer handle up front. The
auto-create form lets the single consumer register itself with
`attachConsumer()` before its first pop, and each producer thread attaches
its own view:

```nim
import lockfreequeues

var q = newUnboundedMupsicQueue[int, stEager, 16, 4]()
q.attachConsumer()             # on the consumer thread, before pop
var p = q.getProducer()
p.attach()                     # on each producer thread, before push
p.push(42)
let v = q.pop()
```

### Unbounded — `UnboundedSipmuc`

```nim
import lockfreequeues
from debra import DebraManager, initDebraManager

# Before
# var mgr = initDebraManager[4]()
# var q = newUnboundedSipmuc[16, int, 4](addr mgr)

# After: manager-borrow form.
var mgr = initDebraManager[4, debra.ccMulti]()
var q = newUnboundedSipmucQueue[int, stEager, 16, 4](addr mgr)
# Or auto-create (queue owns a private manager):
# var q = newUnboundedSipmucQueue[int, stEager, 16, 4]()
```

### Unbounded — `UnboundedMupmuc`

```nim
import lockfreequeues
from debra import DebraManager, initDebraManager

# Before
# var mgr = initDebraManager[4]()
# var q = newUnboundedMupmuc[16, int, 4](addr mgr)

# After: manager-borrow form.
var mgr = initDebraManager[4, debra.ccMulti]()
var q = newUnboundedMupmucQueue[int, stEager, 16, 4](addr mgr)
# Or auto-create:
# var q = newUnboundedMupmucQueue[int, stEager, 16, 4]()
```

### Unbounded — `UnboundedSipsic` (debra-free)

The standalone `UnboundedSipsic` type is gone, but its body is absorbed
into the `(ccSingle, ccSingle)` arm of `Queue` verbatim — same field
layout and committed-flag protocol, still debra-free (no `attach()`
needed). Use the `newUnboundedSipsicQueue` smart constructor, which gains
the unified `[T, ST, S, MaxThreads]` parameter shape:

```nim
import options
import lockfreequeues

# Before
# var q = newUnboundedSipsic[16, int]()

# After: newUnboundedSipsicQueue[T, ST, S, MaxThreads]. Unbounded queues
# push through a producer view; the single consumer pops on the queue.
var q = newUnboundedSipsicQueue[int, stEager, 16, 4]()
var producer = q.getProducer()
producer.push(42)
let v = q.pop()
assert v == some(42)
```

## Selection rules at a glance

When picking the generic parameters for `BQueue` (bounded) or `Queue`
(unbounded), the mapping is:

- **bounded vs unbounded** — `BQueue` for the four ring-buffer families
  (`Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`); `Queue` for the four
  linked-segment families (`UnboundedSipsic`, `UnboundedSipmuc`,
  `UnboundedMupsic`, `UnboundedMupmuc`).
- **`ccProd` / `ccCons`** — match the legacy family's first letter pair:
  `Mu...` -> `ccMulti`, `Si...` -> `ccSingle`. So `Mupsic` is
  `ccProd=ccMulti, ccCons=ccSingle`; `Sipmuc` is the inverse.
- **`N`** (`BQueue` only) — ring-buffer capacity.
- **`P` / `C`** (`BQueue` only) — producer / consumer registry slots;
  only meaningful for the multi-cardinality side. Use `0` on the
  single-cardinality side.
- **`ST`** (`Queue` only) — `stEager` matches the legacy default; pass
  `stManual` explicitly only when the legacy `newUnbounded*(..., Manual)`
  form was in use.
- **`S` / `MaxThreads`** (`Queue` only) — unbounded segment size and
  debra thread-registry capacity. The absorbed-sipsic `(ccSingle,
  ccSingle)` arm is debra-free but still takes a positive `MaxThreads`
  for parameter uniformity.

Both `BQueue` and `Queue` carry `static` validation guards
(`validateBQueueParams` / `validateQueueParams`) that fail at the
caller's instantiation site if the supplied parameter set is incoherent.
The compile error names the offending parameter, giving the same
instantiation-time feedback the legacy per-family types provided.

## Dependency bumps

`lockfreequeues 5.0.0` requires (per the coordinated release wave):

- `typestates >= 0.9.0`
- `nim-debra >= 0.8.0` (only required when instantiating the
  debra-integrated unbounded `Queue` cardinalities; bounded-only
  (`BQueue`) users and the debra-free unbounded SPSC arm do not pull in
  the reclamation path.)
- `nim >= 2.2.0` (unchanged from 4.1.x).

## See also

- `docs/v5.0.0-migration/3.3.11-B-final-shape.md` — the canonical v5.0.0
  surface reference (the two 6-param types `BQueue` / `Queue`, the smart
  constructors, the cardinality `{.error.}` gates).
- `docs/v5.0.0-migration/design-queue-collapse-v5.0.0.md` and
  `docs/v5.0.0-migration/reframe-rationale.md` — historical context for
  the earlier single-10-param-`Queue` design that the final shape
  superseded. Retained for provenance; not the shipped surface.
