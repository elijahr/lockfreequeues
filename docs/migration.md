# Migrating to lockfreequeues 5.0.0

lockfreequeues 5.0.0 is a **SemVer MAJOR** release. The eight per-family
queue type names from the 4.1.x line collapse to **one** unified generic
`Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]`, plus the
(kept-separate) `UnboundedSipsic[S, T]` SPSC type.

**No aliases are provided.** Every typed call site (`var q: Mupsic[...]`,
`var u: UnboundedMupmuc[...]`, etc.) must migrate to the unified
`Queue[T, ...]` form. The migration is mechanical but pervasive: a
typical 4.1.x adopter touches every `import lockfreequeues` call site.

> **Phase 3 — unbounded path availability.** The `RK = rkEbr` (unbounded)
> branch of `Queue` depends on `nim-debra >= 0.8.0` (Phase 3 of the
> coordinated release wave: `typestates 0.9.0` → `nim-debra 0.8.0` →
> `lockfreequeues 5.0.0`). Migration of the four legacy *unbounded*
> families (`UnboundedMupsic`, `UnboundedSipmuc`, `UnboundedMupmuc`) lands
> with the v5.0.0 RC once `nim-debra 0.8.0` is released. The bounded
> families (`RK = rkNone`) migrate immediately. `UnboundedSipsic` is
> unchanged in either path.

## What changed

- **Removed public types**: `Mupsic`, `Sipmuc`, `Mupmuc`, `Sipsic`,
  `UnboundedMupsic`, `UnboundedSipmuc`, `UnboundedMupmuc`. Replaced by
  `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]`.
- **Removed public constructors**: `initMupsic`, `initSipmuc`,
  `initMupmuc`, `initSipsic`, `newUnboundedMupsic`, `newUnboundedSipmuc`,
  `newUnboundedMupmuc`. Replaced by `initQueue[T, ...]()` (bounded,
  `RK = rkNone`) and `newQueue[T, ...](addr mgr, handle)` (unbounded,
  `RK = rkEbr`).
- **`DeallocationStrategy` is now a phantom static type parameter** `ST`
  on `Queue`. The runtime `strategy:` field on the legacy `Unbounded*`
  queues is removed; every `if self.strategy == X` collapses to
  `when ST == X`, and `stManual` vs `stEager` monomorphize separately.
  The legacy enum values `Manual` and `Eager` remain exported as `const`
  aliases for `stManual` / `stEager` to ease grep continuity.
- **Cardinality is now exposed as static phantoms** `ccProd, ccCons` on
  `Queue` (and is threaded through `ThreadHandle[MaxThreads, CC]` on
  every queue field, `Producer*`, and `Consumer*` object).
- **`UnboundedSipsic[S, T]` is unchanged**: no migration required, no
  EBR integration, no phantom additions.
- **No defaults** for `ccProd`, `ccCons`, or `RK`. The unification's
  purpose is to make cardinality and reclamation explicit at the call
  site; defaults would re-introduce the implicit-cardinality ambiguity
  it eliminates. `ST` retains a proc-level default of
  `DefaultDeallocationStrategy` on the constructors.

## Migration table

Every removed public symbol and its unified 5.0.0 replacement. This table
is the authoritative reference for mechanical sed of an existing
4.1.x codebase.

### Type declarations

| Before (4.1.x) | After (5.0.0) |
|---|---|
| `type X = Mupsic[N, P, T]` | `type X = Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]` |
| `type X = Sipmuc[N, C, T]` | `type X = Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0]` |
| `type X = Mupmuc[N, P, C, T]` | `type X = Queue[T, ccMulti, ccMulti, stEager, rkNone, N, P, C, 0, 0]` |
| `type X = Sipsic[N, T]` | `type X = Queue[T, ccSingle, ccSingle, stEager, rkNone, N, 0, 0, 0, 0]` |
| `type X = UnboundedMupsic[S, T, MaxThreads]` | `type X = Queue[T, ccMulti, ccSingle, stEager, rkEbr, 0, 0, 0, S, MaxThreads]` |
| `type X = UnboundedSipmuc[S, T, MaxThreads]` | `type X = Queue[T, ccSingle, ccMulti, stEager, rkEbr, 0, 0, 0, S, MaxThreads]` |
| `type X = UnboundedMupmuc[S, T, MaxThreads]` | `type X = Queue[T, ccMulti, ccMulti, stEager, rkEbr, 0, 0, 0, S, MaxThreads]` |
| `type X = UnboundedSipsic[S, T]` | UNCHANGED — `type X = UnboundedSipsic[S, T]` |

### Constructor call sites

| Before (4.1.x) | After (5.0.0) |
|---|---|
| `var q = initMupsic[N, P, T]()` | `var q = initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()` |
| `var q = initSipmuc[N, C, T]()` | `var q = initQueue[T, ccSingle, ccMulti, stEager, N, 0, C]()` |
| `var q = initMupmuc[N, P, C, T]()` | `var q = initQueue[T, ccMulti, ccMulti, stEager, N, P, C]()` |
| `var q = initSipsic[N, T]()` | `var q = initQueue[T, ccSingle, ccSingle, stEager, N, 0, 0]()` |
| `var q = newUnboundedMupsic[S, T, MaxThreads](addr m, h)` | `var q = newQueue[T, ccMulti, ccSingle, stEager, S, MaxThreads](addr m, h)` |
| `var q = newUnboundedMupsic[S, T, MaxThreads](addr m, h, Manual)` | `var q = newQueue[T, ccMulti, ccSingle, stManual, S, MaxThreads](addr m, h)` |
| `var q = newUnboundedSipmuc[S, T, MaxThreads](addr m)` | `var q = newQueue[T, ccSingle, ccMulti, stEager, S, MaxThreads](addr m)` |
| `var q = newUnboundedMupmuc[S, T, MaxThreads](addr m)` | `var q = newQueue[T, ccMulti, ccMulti, stEager, S, MaxThreads](addr m)` |
| `var q = newUnboundedSipsic[S, T]()` | UNCHANGED — `var q = newUnboundedSipsic[S, T]()` |

> The runtime `strategy:` argument that previously sat on
> `newUnboundedMupsic` / `newUnboundedSipmuc` / `newUnboundedMupmuc` is
> **gone**. To select `stManual` vs `stEager`, write the desired phantom
> directly in the `ST` generic position (e.g., the second row above,
> showing the explicit `stManual` migration).

## Worked examples

The migration below shows each legacy family translated into its v5.0.0
shape, including a typical use that exercises the constructor and one
push/pop.

### Bounded — `Mupsic` (mupsic, multi-producer / single-consumer)

```nim
# Before (4.1.x)
var q = initMupsic[16, 4, int]()
var p = q.getProducer()
p.push(42)
let v = q.pop()

# After (5.0.0)
var q = initQueue[int, ccMulti, ccSingle, stEager, 16, 4, 0]()
var p = q.getProducer()
p.push(42)
let v = q.pop()
```

### Bounded — `Sipmuc` (single-producer / multi-consumer)

```nim
# Before
var q = initSipmuc[16, 4, int]()

# After
var q = initQueue[int, ccSingle, ccMulti, stEager, 16, 0, 4]()
```

### Bounded — `Mupmuc` (multi-producer / multi-consumer)

```nim
# Before
var q = initMupmuc[16, 4, 4, int]()

# After
var q = initQueue[int, ccMulti, ccMulti, stEager, 16, 4, 4]()
```

### Bounded — `Sipsic` (single-producer / single-consumer)

```nim
# Before
var q = initSipsic[16, int]()

# After
var q = initQueue[int, ccSingle, ccSingle, stEager, 16, 0, 0]()
```

### Unbounded — `UnboundedMupsic`

> The `rkEbr` (unbounded) branch ships with the v5.0.0 RC alongside
> `nim-debra 0.8.0`. Code samples below are normative for the upcoming
> RC.

```nim
# Before (4.1.x)
var mgr = initDebraManager[4]()
let h = registerThread(mgr)
var q = newUnboundedMupsic[16, int, 4](addr mgr, h)
# stEager is the runtime default; for Manual, pass the field:
# var q = newUnboundedMupsic[16, int, 4](addr mgr, h, Manual)

# After (5.0.0 RC)
var mgr = initDebraManager[4]()
let h = registerThread(mgr, ccSingle)
var q = newQueue[int, ccMulti, ccSingle, stEager, 16, 4](addr mgr, h)
# For Manual: choose the ST phantom at the call site.
# var q = newQueue[int, ccMulti, ccSingle, stManual, 16, 4](addr mgr, h)
```

> **Note**: The `registerThread` call now takes an explicit
> `PinScopeCardinality` (`ccSingle` or `ccMulti`), which threads through
> as `ThreadHandle[MaxThreads, CC]`. Every fixture or test-object literal
> that types a `ThreadHandle[N]` field needs to add the `CC` parameter.

### Unbounded — `UnboundedSipmuc`

```nim
# Before
var mgr = initDebraManager[4]()
var q = newUnboundedSipmuc[16, int, 4](addr mgr)

# After (5.0.0 RC)
var mgr = initDebraManager[4]()
var q = newQueue[int, ccSingle, ccMulti, stEager, 16, 4](addr mgr)
```

### Unbounded — `UnboundedMupmuc`

```nim
# Before
var mgr = initDebraManager[4]()
var q = newUnboundedMupmuc[16, int, 4](addr mgr)

# After (5.0.0 RC)
var mgr = initDebraManager[4]()
var q = newQueue[int, ccMulti, ccMulti, stEager, 16, 4](addr mgr)
```

### Unbounded — `UnboundedSipsic` (no migration)

```nim
# Before and after — identical.
var q = newUnboundedSipsic[16, int]()
q.push(42)
let v = q.pop()
```

## Selection rules at a glance

When picking the unified `Queue` generic parameters, the mapping is:

- **`ccProd` / `ccCons`** — match the legacy family's first letter pair:
  `Mu...` -> `ccMulti`, `Si...` -> `ccSingle`. So `Mupsic` is
  `ccProd=ccMulti, ccCons=ccSingle`; `Sipmuc` is the inverse.
- **`ST`** — `stEager` matches the legacy default; pass `stManual`
  explicitly only when the legacy `newUnbounded*(..., Manual)` form was
  in use.
- **`RK`** — `rkNone` for the four bounded families (`Mupsic`, `Sipmuc`,
  `Mupmuc`, `Sipsic`); `rkEbr` for the three migrated unbounded families
  (`UnboundedMupsic`, `UnboundedSipmuc`, `UnboundedMupmuc`).
  `UnboundedSipsic` does not enter the generic.
- **`N`** — bounded segment count; `rkNone` queues only. Pass `0` for
  the unbounded branch.
- **`P` / `C`** — `MaxProducers` / `MaxConsumers`; only meaningful for
  the multi-cardinality sides under `rkNone`. Use `0` as the sentinel
  for single-cardinality or unbounded.
- **`S` / `MaxThreads`** — unbounded segment size and debra thread
  registry capacity; `rkEbr` queues only. Pass `0` for bounded.

The unified `Queue` carries `static: assert` guards inside each `RK`
branch that fail at the caller's instantiation site if the supplied
size-param set is incoherent (e.g., `rkEbr` with `S = 0`, or `rkNone`
with `S > 0`). The compile error names the offending parameter, giving
the same instantiation-time feedback the legacy per-family types
provided.

## Dependency bumps

`lockfreequeues 5.0.0` requires (per the coordinated release wave):

- `typestates >= 0.9.0`
- `nim-debra >= 0.8.0` (only required when instantiating `RK = rkEbr`
  queues; bounded-only users can ship against the v5.0.0 line as soon
  as the bounded branch is released.)
- `nim >= 2.2.0` (unchanged from 4.1.x).

## See also

- `docs/v5.0.0-migration/design-queue-collapse-v5.0.0.md` —
  the full v5.0.0 design document (10-param generic, the nine
  `validateQueueParams` guards, the `PinnedScope` migration plan, the
  per-bucket migration impact estimate over ~290 call sites).
- `docs/v5.0.0-migration/reframe-rationale.md` — why the v4.3 → v5.0.0
  reframe happened and what it covers.
