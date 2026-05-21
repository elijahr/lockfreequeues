---
title: lockfreequeues 5.0.0 — Unified `Queue` generic + Cardinality/Strategy/Reclamation phantoms + PinnedScope migration
status: design
generated: 2026-05-16
reframed: 2026-05-17 (v4.2 MINOR -> v5.0.0 MAJOR per operator decision)
companion-understanding: /Users/eek/.local/spellbook/docs/Users-eek-Development-nim-debra/understanding/understanding-pinnedscope-withretireoncas-20260516.md
companion-audit: /Users/eek/.local/spellbook/docs/Users-eek-Development-nim-debra/designs/nim-debra-typestate-audit-2026-05-15.md
upstream-designs:
  - typestates 0.9.0: /Users/eek/.local/spellbook/docs/Users-eek-Development-nim-typestates/designs/design-destructortransition-cfg-analyzer-20260516.md
  - nim-debra 0.8.0:  /Users/eek/.local/spellbook/docs/Users-eek-Development-nim-debra/designs/design-pinnedscope-cc-cascade-20260516.md
release-order: 3 of 3 (typestates 0.9.0 → nim-debra 0.8.0 → lockfreequeues 5.0.0)
target-nim: ">= 2.2.0" (existing lockfreequeues.nimble:11; unchanged)
---

## 1. Release Goal

> **BREAKING NOTICE — lockfreequeues 5.0.0 is a SemVer MAJOR release.**
> The eight per-family queue type names from 4.1.x (`Mupsic`, `Sipmuc`,
> `Mupmuc`, `Sipsic`, `UnboundedMupsic`, `UnboundedSipmuc`,
> `UnboundedMupmuc`, `UnboundedSipsic`) collapse to **one** unified
> generic `Queue[T, ccProd, ccCons, ST, RK, ...]` plus the (kept-separate)
> `UnboundedSipsic[S, T]` SPSC type. **NO short-form or long-form aliases
> are provided.** Every typed call site (`var q: Mupsic[...]`,
> `var u: UnboundedMupmuc[...]`, etc.) MUST migrate to the unified
> `Queue[T, ...]` form. The CHANGELOG opens with a full migration table;
> see §2.5 and §5.

lockfreequeues 5.0.0 is the **third and final** release of the
coordinated wave (typestates 0.9.0 → nim-debra 0.8.0 →
lockfreequeues 5.0.0). It applies the upstream `PinnedScope[MT, CC]` +
`retireOnCAS` + CC-cascade work to the unbounded queue family, lifts
`DeallocationStrategy` from a runtime field to a compile-time phantom,
and **unifies the eight bounded+unbounded queue families into one
generic** `Queue[T, ccProd, ccCons, ST, RK, ...]`. The `RK` (reclamation
kind) phantom is now load-bearing: `RK = rkNone` selects the bounded
body (Vyukov seq counters, no EBR); `RK = rkEbr` selects the unbounded
body (LCRQ-style segmented + nim-debra reclamation). `UnboundedSipsic`
remains a separate type at `src/lockfreequeues/unbounded_sipsic.nim` —
it has no retire-race (SPSC) and forcing it into `Queue` would either
require an unused EBR path or a second unbounded body in the generic.

After this release:

1. **`DeallocationStrategy`** is consolidated into a single shared module
   (`src/lockfreequeues/strategy.nim`) — removing the three identical enum
   definitions at `unbounded_mupsic.nim:52`, `unbounded_mupmuc.nim:50`, and
   `unbounded_sipmuc.nim:54` (verified).

2. **`ST` (DeallocationStrategy) is a phantom static type parameter** on
   the unified `Queue` generic. The runtime `strategy` field on every
   `Unbounded*` queue object is removed; every runtime
   `if self.strategy == X` collapses to `when ST == X` and `stManual` vs
   `stEager` monomorphize separately. `UnboundedSipsic` does not gain
   `ST` (no EBR integration — verified at `unbounded_sipsic.nim` which
   never imports `debra`).

3. **Cardinality is exposed as static phantoms `ccProd, ccCons` on
   `Queue`**, and threaded through `ThreadHandle[MaxThreads, CC]` (the
   nim-debra 0.8.0 extension) on every queue field, `Producer*`, and
   `Consumer*` object. Per-queue-family ccProd/ccCons values: an EBR
   "mupsic-equivalent" is `Queue[T, ccMulti, ccSingle, ST, rkEbr]`; an
   "unbounded-mupmuc-equivalent" is `Queue[T, ccMulti, ccMulti, ST,
   rkEbr]`; etc. Bounded queues take `RK = rkNone` and omit the EBR
   wrappers entirely.

4. **All 5 `withPin` sites migrate to `PinnedScope` + `retireOnCAS`**:
   - 3 retire-bearing pop paths (`unbounded_mupsic.nim:337`,
     `unbounded_mupmuc.nim:351`, `unbounded_sipmuc.nim:299`) — verified
     against the live source.
   - 2 producer-push pin-only paths (`unbounded_mupsic.nim:252`,
     `unbounded_mupmuc.nim:268`) — verified against the live source.
   The mupsic-equivalent consumer-side `headSegment` store-publish at
   `unbounded_mupsic.nim:370` is routed to the per-queue
   `q.retireOnPublish(...)` wrapper (§3.0.2; nim-debra design §3.4.1
   selection rule). The two MPMC/SPMC Consumer.pop CAS sites use
   `q.retireOnCAS(...)`.

5. **The 25-file `src/lockfreequeues/typestates/` scaffolding** gains
   the CC phantom on every `ThreadHandle[MT]`, `Pinned[MT]`, and
   `EpochGuardContext[MT]` reference in the 6 debra-aware files. The
   other 19 files are untouched (verified).

6. **Tests + examples migrate to the unified `Queue` shape.** All ~308
   call sites in `src/` + `tests/` mechanically convert; no caller
   compiles unchanged. See §4 for the per-bucket impact estimate.

7. **CHANGELOG `## [5.0.0]`** opens with a **BREAKING NOTICE** block
   enumerating every removed name + its unified replacement. A full
   migration table accompanies. Version bump `lockfreequeues.nimble:6`
   4.1.0 → 5.0.0, dependency bumps `debra >= 0.8.0` and
   `typestates >= 0.9.0`.

**Migration impact summary (re-derived for v5.0.0)**: Verified by grep
over `src/` + `tests/`: **167 typed bindings** of the eight legacy
queue names (`Mupsic[...]`, `Sipmuc[...]`, ..., `UnboundedSipsic[...]`)
and **141 constructor call sites** (`initMupsic(...)`,
`newUnboundedMupsic(...)`, etc.). Of those, the `UnboundedSipsic` and
`initSipsic`/`newUnboundedSipsic` sites are unaffected (the SPSC types
are preserved). The remaining ~290+ sites all migrate to the
`Queue[T, ...]` form. Migration is **mechanical but pervasive** — no
"transparent" subset under the new framing.

> **Note (file provenance):** This document was originally drafted as
> `design-strategy-cardinality-phantoms-v4.2-20260516.md` in the
> spellbook designs directory during the v4.2 → v5.0.0 reframe. It was
> originally filed in the repo as
> `docs/v5.0.0-migration/design-queue-collapse-v5.0.0-20260516.md` and
> renamed 2026-05-21 to
> `docs/v5.0.0-migration/design-queue-collapse-v5.0.0.md` (dropping the
> temporary date stamp now that v5.0.0 is the only ongoing design).
> The spellbook copy is orphan history; this file is authoritative
> going forward.

## 2. Scope & Non-Goals

### IN scope

- **lockfreequeues 5.0.0 (MAJOR)** — explicit operator-approved breaking
  change. Drops alias-preservation strategy; introduces unified `Queue`
  generic.
- **Bounded queues are IN SCOPE** — they collapse into the unified
  `Queue` generic with `RK = rkNone`. The existing per-family bounded
  files (`mupsic.nim`, `sipmuc.nim`, `mupmuc.nim`, `sipsic.nim`)
  collapse into the unified body (Phase 3 picks file layout — single
  `queue.nim` vs split per-RK files vs per-cardinality files; the
  public API surface is identical either way).
- **Unbounded queues (sans UnboundedSipsic) are IN SCOPE** — collapse
  into `Queue` with `RK = rkEbr`.
- New file `src/lockfreequeues/strategy.nim` containing the single
  shared `DeallocationStrategy*` enum and `DefaultDeallocationStrategy*`
  constant.
- New file `src/lockfreequeues/reclamation.nim` containing the
  `ReclamationKind*` enum (`rkNone`, `rkEbr`).
- Unified `Queue*[T; ccProd, ccCons: static PinScopeCardinality;
  ST: static DeallocationStrategy; RK: static ReclamationKind;
  N, S, MaxThreads: static int]` generic. See §3.0 for the field-layout
  rationale.
- `Strategy` (`ST`) phantom: active on the `RK = rkEbr` branch; `rkNone`
  branch ignores `ST` (Phase 3 picks whether to require a dummy value or
  default `ST = stEager` when `RK = rkNone` — see §3.0 and §3.1).
- ThreadHandle CC threading on every queue object field and on every
  `Producer*` / `Consumer*` object that holds a handle. The CC value
  is fixed per (`ccProd`, `ccCons`) family per §3.3 table.
- Migration of all 5 `withPin` sites to `pinScope(unpinned(handle))`
  returning a `PinnedScope[MaxThreads, CC]` (RAII via `=destroy`).
- Use of `q.retireOnCAS(...)` / `q.retireOnPublish(...)` per §3.0.2.
- Removal of the `strategy: DeallocationStrategy` field from every
  unbounded queue.
- CC cascade on 6 files in `src/lockfreequeues/typestates/` (the
  debra-aware scaffolding files; see §3.6 per-file table).
- Migration of every typed call site in `tests/` + `examples/` to the
  unified `Queue[T, ...]` shape (~290 sites; see §4).
- New tests covering: Strategy phantom monomorphization (Manual / Eager
  × multiple cardinalities); bounded-vs-unbounded retireOnCAS guard
  (compile-fail on `RK = rkNone`); cardinality mismatch (compile-fail
  on Consumer/handle).
- New CHANGELOG entry opening with a **BREAKING NOTICE** block.
- `lockfreequeues.nimble` version bump 4.1.0 → **5.0.0** and dependency
  bumps to `debra >= 0.8.0` and `typestates >= 0.9.0`.

### EXPLICITLY OUT OF SCOPE

- **`UnboundedSipsic` modifications** — kept entirely as-is at
  `src/lockfreequeues/unbounded_sipsic.nim:30` (`UnboundedSipsic*[S:
  static int, T] = object`). It does not enter the `Queue` generic
  because it does not need EBR reclamation (one producer, one consumer;
  no retire-race), and forcing it into `Queue` via
  `when RK == rkEbr and ccProd == ccSingle and ccCons == ccSingle`
  would either waste runtime on EBR ops the contract does not need or
  require a second unbounded body in the generic. See §3.0.3 for the
  rationale.
- **Aliases of any kind**. NO `Mupsic` / `Sipmuc` / `Mupmuc` / `Sipsic`
  / `UnboundedMupsic` / etc. type aliases over `Queue`. Operator
  decision 2026-05-17: every caller instantiates `Queue[T, ...]`
  directly. The §1 framing of "transparent aliasing for SemVer MINOR"
  is GONE.
- The 19 typestate scaffolding files without debra references
  (`atomic_loaders`, `cas`, `fullness_checks`, etc.) — untouched.
- Performance optimization, benchmarking, or hot-path microbenches —
  the release is correctness + ergonomics. Existing benchmark
  scaffolding (`benchmarks/`, `tests/t_bench_*`) is untouched.
- New queue types or new public API surface beyond the unified `Queue`
  generic and the kept-separate `UnboundedSipsic` type.
- Removing `withPin` from nim-debra (deprecation only; removal
  scheduled for nim-debra's next major release per upstream design §1).
- Avocado's β3+β4 work content — coordinated separately via pepper
  relay (see §3.8).

### MVP DEFINITION

A working slice that ships in one PR / one tag / one CHANGELOG entry:

- `strategy.nim` and `reclamation.nim` shared modules exist.
- `Queue*` unified generic exists at
  `src/lockfreequeues/queue.nim` (Phase 3 picks final file layout) and
  exposes the `RK = rkNone` (bounded) and `RK = rkEbr` (unbounded)
  branches via `when` blocks in the type body and method bodies.
- `UnboundedSipsic` is unchanged.
- All 5 `withPin` sites compile and run under `PinnedScope` +
  `retireOnCAS` / `retireOnPublish`.
- All 6 `when ST ==` blocks branch correctly for both `stManual` and
  `stEager`.
- Every existing typed call site in `tests/` + `examples/` migrated to
  `Queue[T, ...]`.
- 6 debra-aware typestate scaffolding files compile under the CC cascade.
- New tests: Strategy monomorphization × cardinality matrix;
  bounded-vs-unbounded retire guard compile-fail; CC mismatch compile-fail.
- Full `nimble test` matrix (orc / arc / refc / cpp /
  `nimEnforceLockFreeAtomics`) green. Sanitizer matrix (TSAN / ASAN,
  gated by `SANITIZE_*` env vars) green when enabled.

## 2.5 Versioning constraint (SemVer MAJOR — v5.0.0)

lockfreequeues 4.1.0 → **5.0.0** is a SemVer **MAJOR** bump. The
operator's 2026-05-17 directive ("we don't care about backwards compat
for unbounded") generalises to bounded as well: the unified `Queue`
generic is worth the break.

**What the MAJOR bump covers:**

- **Removed public type names**: `Mupsic`, `Sipmuc`, `Mupmuc`, `Sipsic`,
  `UnboundedMupsic`, `UnboundedSipmuc`, `UnboundedMupmuc`. Replaced by
  `Queue[T, ccProd, ccCons, ST, RK, ...]`.
- **Removed public constructor procs**: `initMupsic`, `initSipmuc`,
  `initMupmuc`, `initSipsic`, `newUnboundedMupsic`, `newUnboundedSipmuc`,
  `newUnboundedMupmuc`. Replaced by `initQueue[T, ...](...)` (bounded
  RK = rkNone branch) and `newQueue[T, ...](addr mgr, handle)`
  (unbounded RK = rkEbr branch).
- **Removed runtime `strategy:` arg** on unbounded constructors.
  Replaced by the `ST` static phantom on `Queue`.
- **Public field type change**: every `ThreadHandle[N]` annotation in a
  fixture or test object literal needs CC: `ThreadHandle[N, ccSingle]`
  or `ThreadHandle[N, ccMulti]`.
- **No defaults** for `ccProd`, `ccCons`, `RK` on `Queue`. The operator
  has explicitly chosen "force callers to write the cardinality and
  reclamation kind they want." Defaults would re-introduce the
  "implicit cardinality" ambiguity that the unification is meant to
  eliminate. The `ST` parameter retains a proc-level default of
  `DefaultDeallocationStrategy` on the constructor procs (same
  mechanism as §3.2 in the prior revision — proc-level static-defaults
  work; type-level do not).

**What survives unchanged:**

- `UnboundedSipsic*[S: static int, T] = object` at
  `src/lockfreequeues/unbounded_sipsic.nim:30`. Its constructor
  `newUnboundedSipsic`, its methods, its tests — all unchanged. The
  type stays outside the `Queue` generic per §3.0.3.
- The `DeallocationStrategy` enum *values* (`Manual`, `Eager`) remain
  exported as `const` aliases for `stManual` / `stEager` per §3.1
  (helps grep continuity even though every call site is migrating
  anyway).

**CHANGELOG mandate** (also §5):

The `## [5.0.0]` section MUST open with a **BREAKING NOTICE** block:

```
## [5.0.0] - 2026-MM-DD

### BREAKING CHANGES

This is a MAJOR release. Every typed call site against the previous
public API surface must migrate. See the migration table below.

REMOVED public types:
  - Mupsic[N, P, T]                       -> Queue[T, ccMulti, ccSingle, ST, rkNone, N, P, _]
  - Sipmuc[N, C, T]                       -> Queue[T, ccSingle, ccMulti, ST, rkNone, N, _, C]
  - Mupmuc[N, P, C, T]                    -> Queue[T, ccMulti, ccMulti, ST, rkNone, N, P, C]
  - Sipsic[N, T]                          -> Queue[T, ccSingle, ccSingle, ST, rkNone, N, _, _]
  - UnboundedMupsic[S, T, MaxThreads]     -> Queue[T, ccMulti, ccSingle, ST, rkEbr, _, _, MaxThreads, S]
  - UnboundedSipmuc[S, T, MaxThreads]     -> Queue[T, ccSingle, ccMulti, ST, rkEbr, _, _, MaxThreads, S]
  - UnboundedMupmuc[S, T, MaxThreads]     -> Queue[T, ccMulti, ccMulti, ST, rkEbr, _, _, MaxThreads, S]

REMOVED public constructors (replaced by initQueue / newQueue, see migration table).

REMOVED public field: every `strategy: DeallocationStrategy` field on
the unbounded queue objects (ST is now a static phantom).

KEPT unchanged: UnboundedSipsic[S, T] and its newUnboundedSipsic
constructor (SPSC unbounded has no retire-race, stays outside the
unified generic).

### Migration table

[per-symbol before/after examples — see §5]
```

The CHANGELOG's migration table is the authoritative artefact for v5.0.0
adopters. Its quality bar is "an existing 4.1.x user can mechanically
sed their codebase from the table without re-reading the design doc."
This is a release blocker; the doc CHANGELOG section in §5 has the
full template.

## 3. Architecture

### 3.0 Unified `Queue` generic (cardinality + strategy + reclamation)

**Decision** (operator 2026-05-17, supersedes all prior revisions of this
section): **COLLAPSE the seven non-SPSC-unbounded queue families
(`Mupsic` / `Sipmuc` / `Mupmuc` / `Sipsic` bounded + `UnboundedMupsic`
/ `UnboundedSipmuc` / `UnboundedMupmuc` unbounded) into ONE unified
generic** `Queue[T, ccProd, ccCons, ST, RK, ...]`. **NO aliases of any
kind.** Bounded and unbounded share the type name; they are distinguished
by the `RK` phantom which is *load-bearing in the type body* (selects
between two distinct field layouts via `when RK == rkNone:` vs
`when RK == rkEbr:`).

`UnboundedSipsic[S, T]` remains a separate type — see §3.0.3.

#### Target shape

```nim
type
  Queue*[T;
         ccProd, ccCons: static PinScopeCardinality;
         ST: static DeallocationStrategy;
         RK: static ReclamationKind;
         N, P, C, S, MaxThreads: static int] = object
    # Bounded (Vyukov seq counters; no debra, no segments).
    when RK == rkNone:
      # Param-coherence guards (see §3.0.2.4). These fail at type-decl
      # time with an actionable message, preserving the quality-of-error
      # the legacy per-family types (`Mupsic[N, P: static int, T]`, etc.)
      # gave by construction.
      static: assert N > 0,
        "Queue[..., RK=rkNone] requires N > 0 (bounded slot count)"
      static: assert S == 0 and MaxThreads == 0,
        "Queue[..., RK=rkNone] must have S=0, MaxThreads=0 " &
        "(segment-size and thread-registry are rkEbr-only)"
      when ccProd == ccMulti:
        static: assert P > 0,
          "Queue[..., ccProd=ccMulti, RK=rkNone] requires P > 0 " &
          "(per-producer state count)"
      when ccProd == ccSingle:
        static: assert P == 0,
          "Queue[..., ccProd=ccSingle, RK=rkNone] must have P == 0"
      when ccCons == ccMulti:
        static: assert C > 0,
          "Queue[..., ccCons=ccMulti, RK=rkNone] requires C > 0 " &
          "(per-consumer state count)"
      when ccCons == ccSingle:
        static: assert C == 0,
          "Queue[..., ccCons=ccSingle, RK=rkNone] must have C == 0"
      # ccProd / ccCons phantoms still gate per-method specialisation
      # (single-producer push uses simple-store + seq publish; multi-
      # producer push uses CAS-loop). Slots are inline:
      slots: array[N, Slot[T]]
      producerSeq: Atomic[int]                  # gated by ccProd
      consumerSeq: Atomic[int]                  # gated by ccCons
      # ccCons == ccMulti adds a per-consumer head-tracking array, etc.
      # Specific bounded field layout matches the existing
      # mupsic/sipmuc/mupmuc/sipsic field shapes (per §3.0.1).
    # Unbounded (LCRQ-style segmented + debra reclamation).
    elif RK == rkEbr:
      # Param-coherence guards (see §3.0.2.4). These fail at type-decl
      # time with an actionable message, preserving the quality-of-error
      # the legacy per-family types (`UnboundedMupsic[S, T, MaxThreads]`,
      # etc.) gave by construction.
      static: assert S > 0,
        "Queue[..., RK=rkEbr] requires S > 0 (segment slot count)"
      static: assert MaxThreads > 0,
        "Queue[..., RK=rkEbr] requires MaxThreads > 0 " &
        "(debra thread-registry capacity)"
      static: assert N == 0 and P == 0 and C == 0,
        "Queue[..., RK=rkEbr] must have N=0, P=0, C=0 " &
        "(bounded slot/per-producer/per-consumer counts are rkNone-only)"
      manager: ptr DebraManager[MaxThreads]
      headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      tailSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      itemCount: Atomic[int]
      segments: Atomic[int]
      ownsManager: bool
      when ccProd == ccMulti:
        producerCount: Atomic[int]
      when ccCons == ccMulti:
        consumerCount: Atomic[int]
      when ccProd == ccMulti and ccCons == ccSingle:
        # mupsic-equivalent: single-consumer handle lives on the queue.
        handle: ThreadHandle[MaxThreads, ccSingle]
      when ccCons == ccMulti:
        # Multi-consumer family uses a per-consumer head index array.
        consumerHeads: array[MaxThreads, Atomic[int]]
```

The seven generic parameters (`T`, `ccProd`, `ccCons`, `ST`, `RK`, plus
the size constants `N`, `P`, `C`, `S`, `MaxThreads`) are all carried
uniformly so the type signature is one shape. See §3.0.2 for the
static-param treatment decision.

#### 3.0.1 Static parameter treatment: uniform generic

**Decision**: option **(b) all-uniform-generic** — every queue
instantiation names all required generic params. Size params that are
not used by a given RK branch are written as `_` (placeholder int) by
callers, with documented "only used when RK == rkNone" / "only used
when RK == rkEbr" semantics.

Concretely:

- `N` (slot array size) — used when `RK == rkNone`. When `RK == rkEbr`
  callers may pass `0` or `_` (Phase 3 picks the placeholder convention
  — likely `0` since Nim does not natively support `_` in static int
  positions).
- `P` (producer count, bounded multi-producer per-producer state size)
  — used when `RK == rkNone and ccProd == ccMulti`; ignored otherwise.
- `C` (consumer count, bounded multi-consumer per-consumer state size)
  — used when `RK == rkNone and ccCons == ccMulti`; ignored otherwise.
- `S` (segment slot count) — used when `RK == rkEbr`.
- `MaxThreads` (debra thread registry capacity) — used when `RK == rkEbr`.

**Rationale for option (b) over option (a) branch-conditional generics**:

- **Uniform type signature** — `Queue[T, ccP, ccC, ST, RK, N, P, C, S,
  MaxThreads]` is one shape; the user never has to know "do I write
  `Queue[T, _, _, _, _, N, P, C]` or `Queue[T, _, _, _, _, _, _, _, S,
  MT]` based on which RK I want." The type's identity is uniform.
- **No "phantom of a phantom" complexity** — option (a) would require
  conditionally-existing generic params, which Nim does not natively
  support. Implementing it would mean either (i) two separate `Queue`
  types (defeats unification) or (ii) defining `Queue` as a macro that
  expands to one of two underlying type definitions (defeats type-level
  inference and clean codegen).
- **Codegen clarity** — `when RK == ...:` branches in the type body
  produce one concrete object layout per RK value; the unused size
  params are erased (Nim's generic instantiation drops phantom statics
  that don't reach the field layout). Confirmed safe via the same
  mechanism used by `UnboundedSipsic`'s `S` parameter today (the
  segment size is a phantom that drives only `array[S, T]` field sizing).
- **Caller ergonomics with `_` placeholders** — Phase 3 may add a
  helper `const _ = 0` or document the convention so call sites read
  cleanly: `Queue[int, ccMulti, ccSingle, stEager, rkEbr, _, _, _, 16,
  4]` clearly says "bounded params unused; segment-16, threads-4."
  Alternatively Phase 3 may introduce **smart-constructor procs**
  (`bounded.newMupsicEquivalent[N, P, T]()` etc.) as ergonomic helpers
  that derive the full Queue type — but those would be call-site
  ergonomic shorthands only, not type aliases. See §3.0.4.

The doc retains option (b) as the canonical shape; Phase 3 picks the
exact placeholder convention.

#### 3.0.2 Bounded-asymmetry guard (γ): per-queue retireOnCAS / retireOnPublish

The nim-debra library exports `retireOnCAS` / `retireOnPublish` on
`PinnedScope[MT, CC]`, **unguarded with respect to queue type**.
nim-debra is queue-agnostic by design.

Lockfreequeues localizes the bounded-vs-unbounded guard by defining
the wrappers **as methods on the unified `Queue` type, but ONLY for
the `RK = rkEbr` branch**:

```nim
proc retireOnCAS*[T; ccProd, ccCons; ST; CC; N, P, C, S, MaxThreads; U](
  q: var Queue[T, ccProd, ccCons, ST, rkEbr, N, P, C, S, MaxThreads];
  scope: var PinnedScope[MaxThreads, CC];
  atomic: var Atomic[U]; expected, new: U;
  dtor: DestructorProc[U]
): bool =
  ## Defined ONLY for `RK = rkEbr` (the unbounded branch). On bounded
  ## queues (`RK = rkNone`), this proc is absent — UFCS lookup fails
  ## with method-not-defined. That IS the bounded-asymmetry guard.
  scope.retireOnCAS(atomic, expected, new, dtor)

proc retireOnPublish*[T; ccProd; ST; CC; N, P, C, S, MaxThreads; U](
  q: var Queue[T, ccProd, ccSingle, ST, rkEbr, N, P, C, S, MaxThreads];
  scope: var PinnedScope[MaxThreads, CC];
  atomic: var Atomic[U]; new: U;
  dtor: DestructorProc[U]
) =
  ## Defined only for `RK = rkEbr` AND `ccCons = ccSingle` — single-
  ## writer publish path. nim-debra §3.4.1 selection rule.
  scope.retireOnPublish(atomic, new, dtor)
```

UFCS resolution: `q.retireOnCAS(...)` resolves only when `q` is an
EBR-backed unbounded `Queue`; on a bounded `Queue` (`RK = rkNone`) it
fails to compile with method-not-defined. On unbounded queues with at
least one `ccMulti` participant, `q.retireOnPublish(...)` fails to
compile (no matching overload) and the caller must use `q.retireOnCAS`.

**⚠ FOOT-GUN — `retireOnPublish` requires a single-writer publish
atomic**: even though the per-queue wrapper above gates on
`ccCons == ccSingle`, that gate is a sufficient-but-not-necessary
heuristic. The actual soundness property is per-atomic: the CALLER
must assert the published atomic is single-writer for the duration
of the retire. Misuse on a multi-writer atomic produces SILENT data
corruption (the retire chain assumes no concurrent store can race the
publish). The wrapper's cardinality gate covers the canonical sites
(mupsic-equivalent consumer-side `headSegment` advance) but cannot
enforce the property in general. See nim-debra design §3.4.1 for the
full annotation and worked mupsic example.

**Note on advanced use**: a user can still invoke the nim-debra
primitive directly via `scope.retireOnCAS(boundedQueue.atomicField,
...)` and side-step the guard. This is architecturally weird (an
arbitrary `Atomic[T]` carries no information about what owns it), and
nim-debra cannot guard it. Document as: "advanced use; library cannot
guard if user bypasses the per-queue wrapper."

The (γ) shape was selected over the (α) factory-method-gating proposal
(PinnedScope construction via per-queue `pinnedScope()` method) because:

- `PinnedScope` is per-thread-handle, not per-queue, in nim-debra's
  architecture.
- Multi-queue-per-manager is the WHOLE POINT of EBR's epoch-shared
  design.
- (α) would impose a reverse dependency (nim-debra → lockfreequeues).
  Bad layering.
- (γ) localizes the guard where the bounded-vs-unbounded distinction
  LIVES (lockfreequeues), and **fits naturally into the unified
  generic** because the type-level `when RK == ...` selects the body
  AND the wrapper presence in lockstep.

The three retire-bearing sites enumerated in §3.5 route through the
per-queue wrappers (not the raw nim-debra primitive):

- §3.5.1 (mupsic-equivalent consumer-side `headSegment` advance —
  single-writer publish, `ccCons == ccSingle`):
  `q.retireOnPublish(scope, atomic, new, dtor)`.
- §3.5.2 (mupmuc-equivalent Consumer.pop CAS — multi-consumer race,
  `ccCons == ccMulti`): `q.retireOnCAS(scope, atomic, expected, new, dtor)`.
- §3.5.3 (sipmuc-equivalent Consumer.pop CAS — multi-consumer race,
  `ccCons == ccMulti`): `q.retireOnCAS(scope, atomic, expected, new, dtor)`.

#### 3.0.2.4 Param-coherence guards (quality-of-error preservation)

The unified `Queue` generic carries ten parameters
(`T`, `ccProd`, `ccCons`, `ST`, `RK`, `N`, `P`, `C`, `S`, `MaxThreads`),
of which only a subset is meaningful in each `RK` branch (§3.0.1
option (b) — uniform generic with documented "ignored in this branch"
sentinel `0` for unused size params). The `when RK == rkNone:` /
`elif RK == rkEbr:` switch in the type body selects field layout but
does NOT by itself validate the size-param set the caller supplied.

Without explicit guards, a caller could write something like
`Queue[int, ccMulti, ccSingle, stEager, rkEbr, N=8, S=0, MaxThreads=0]`
(`rkEbr` but no segment size, no thread-registry capacity, plus stray
bounded `N`) and the type would *appear to compile* at the declaration
site. The mistake would surface only later, at the first method body
that references the missing fields — producing an error pointing at
library internals rather than the call site, with no hint of which
parameter is wrong.

This is a regression vs the **legacy per-family types** (`Mupsic[N, P:
static int, T]`, `UnboundedMupsic[S, T, MaxThreads]`, etc.), which made
every meaningful size param a *required* generic position. Under those
types, omitting a size param was a parse/instantiation error at the
caller's instantiation site with the parameter name in the error
message.

The `static: assert` guards inserted at the top of each `when RK`
branch of the type body (see §3.0.1 listing) **preserve that
quality-of-error**:

- `RK == rkNone` branch asserts `N > 0`, `S == 0 and MaxThreads == 0`,
  and (gated on cardinality) `P > 0` / `C > 0` for multi-cardinality
  participants and `P == 0` / `C == 0` for single-cardinality
  participants.
- `RK == rkEbr` branch asserts `S > 0`, `MaxThreads > 0`, and
  `N == 0 and P == 0 and C == 0`.

Assertions are **inside** the `when RK` branches so each branch's
guards run only when that branch is selected. Each assert carries a
plain-English message naming the offending parameter and the constraint
it violated, so the resulting compile error points at the caller's
`Queue[...]` instantiation with a single-line "what you need to fix"
diagnostic. Combined with the uniform-generic shape (§3.0.1), this
gives v5.0.0 callers the same instantiation-time feedback the legacy
per-family types provided, despite the ten-position generic surface.

**No runtime cost**: `static: assert` is evaluated at compile time and
produces no runtime check. **No codegen change**: assertions do not
participate in field layout. **No ergonomic escape hatch**: the guards
are the *only* place coherence is enforced — the doc deliberately does
not provide alias types, smart-constructor procs that hide them, or
helper macros. Per operator philosophy, the caller writes the
parameters explicitly and the type validates them at the type site.

If Phase 3 later determines the assertion messages need richer
formatting (e.g., dumping the full `Queue[...]` shape), the
`assert ... , msg` form supports any compile-time-known string
expression; Phase 3 may extend the messages without changing the
guard structure.

This guard surface is treated as a soundness gate, not a risk — the
failure mode is fully eliminated, not merely mitigated. (This is why
no entry is added to the Risk Register §8: risks describe residual
unmitigated concerns; this guard closes a previously-unmitigated gap.)

#### 3.0.3 `UnboundedSipsic` stays separate (option (a) keep-separate)

**Operator decision 2026-05-17**: `UnboundedSipsic[S, T]` remains its
own type at `src/lockfreequeues/unbounded_sipsic.nim` outside the
unified `Queue` generic.

**Rationale**:

- **No retire-race**: SPSC has one producer and one consumer; the
  producer never reads memory the consumer is freeing and vice versa.
  EBR reclamation machinery is unnecessary; the existing
  `UnboundedSipsic` deallocates segments via the consumer thread
  directly without any debra integration (verified:
  `unbounded_sipsic.nim` has zero `import debra`, zero `withPin`, zero
  `DeallocationStrategy` field).
- **Forcing it into `Queue` would harm rather than help**: encoding
  SPSC unbounded as `Queue[T, ccSingle, ccSingle, ST, rkEbr, ...]`
  would either (i) execute EBR ops on every push/pop that the SPSC
  contract does not require (wasted runtime), or (ii) require a second
  unbounded body in the generic — `when RK == rkEbr and ccProd ==
  ccSingle and ccCons == ccSingle: ... else: ...` — which duplicates
  the field layout decision tree and complicates the `when` ladder
  inside push/pop bodies. The "one body per RK" mental model breaks.
- **No alias loss**: under the no-alias rule (§3.0), there would be no
  ergonomic gain to having `UnboundedSipsic` inside `Queue` either —
  callers would write `Queue[T, ccSingle, ccSingle, _, rkEbr, _, _, _,
  16, 4]` instead of `UnboundedSipsic[16, int]`, gaining nothing.

`UnboundedSipsic` is preserved verbatim. Its public API (constructor
`newUnboundedSipsic`, methods, fields) is unchanged.

#### 3.0.4 Optional ergonomic constructor shorthands (Phase 3 decision)

Phase 3 may introduce smart-constructor procs as call-site shorthands.
These are NOT type aliases (no `type X = Queue[...]`); they are procs
that return a fully-specified `Queue[T, ...]`:

```nim
# OPTIONAL — Phase 3 decides per-need basis. Doc default: do NOT add.
proc newMupsicQueue*[N, P: static int, T](
): Queue[T, ccMulti, ccSingle, DefaultDeallocationStrategy, rkNone,
         N, P, 0, 0, 0] {.inline.} =
  initQueue[T, ccMulti, ccSingle, DefaultDeallocationStrategy, rkNone,
            N, P, 0, 0, 0]()

# ... and analogous helpers for the other 6 families ...
```

**Default position**: do NOT add. Operator decision is "callers
instantiate `Queue[T, ...]` directly." Shorthands would re-introduce a
weaker form of the alias problem (callers learn the helpers, not the
underlying generic). If a shorthand emerges as load-bearing during
Phase 3 migration (e.g., `tests/` becomes unreadable with bare `Queue`
instantiations) the operator is consulted before adding any.

#### 3.0.5 Internal ReclamationKind enum (now load-bearing)

```nim
type
  ReclamationKind* = enum
    rkNone   ## Bounded queues: no reclamation machinery (Vyukov seqlocks).
    rkEbr    ## Unbounded queues: EBR via nim-debra.
```

In v5.0.0 this phantom is **load-bearing in `Queue`'s field selection**
and **public** (callers MUST specify it). There is **NO default** for
`RK` — Phase 3 deliberately does not supply one because the choice is
semantically important (bounded vs unbounded is not a "small detail";
forcing the caller to write it documents intent at the type site).

**Rationale**: the prior v4.2 framing kept `ReclamationKind` internal
with `RK = rkEbr` baked into the alias. Under v5.0.0's no-alias rule,
that approach is untenable — the caller must select RK somehow, and
defaulting to either branch would silently hide a major architectural
choice. Forcing explicit `RK = rkNone` or `RK = rkEbr` at every call
site is the clean alternative.

### 3.1 Strategy enum consolidation

Today `DeallocationStrategy* = enum {Manual, Eager}` and
`DefaultDeallocationStrategy* = Manual|Eager` (under
`when defined(gcNone)`) are defined **identically three times** —
verified at:

- `src/lockfreequeues/unbounded_mupsic.nim:52-64`.
- `src/lockfreequeues/unbounded_mupmuc.nim:50-62`.
- `src/lockfreequeues/unbounded_sipmuc.nim:54-66`.

This triplication is a long-standing code smell. The Strategy-as-phantom
lift forces consolidation: three distinct nominal enums with the same
name would break the unified `Queue` generic.

**New file** `src/lockfreequeues/strategy.nim`:

```nim
## Shared `DeallocationStrategy` enum for the unbounded branch of Queue.
##
## Consolidated in v5.0.0. Lifted from runtime field to phantom static
## type parameter `ST` on the unified `Queue` generic.

type DeallocationStrategy* = enum
  stManual    ## Reserved for future batch-retire; no specialization in v5.0.
  stEager     ## Active in v5.0; per-pop best-effort `reclaimNow(handle)`.

# Bare-symbol aliases. Even under v5.0.0's breaking-change posture these
# `const`s help users transitioning from 4.1.x code that wrote bare
# `Manual` / `Eager`. Nim enum values cannot be aliased; these are
# `const` bindings:
const
  Manual* = stManual
  Eager*  = stEager

when defined(gcNone):
  const DefaultDeallocationStrategy* = stManual
else:
  const DefaultDeallocationStrategy* = stEager
```

**`ST` semantics under `RK = rkNone`**: bounded queues do not use the
strategy phantom (no retire path). Phase 3 picks between (a) requiring
callers to pass a dummy `ST` value (consistent uniform generic; trivial
to write `stEager` everywhere), or (b) defining the bounded constructor
shorthands at §3.0.4 to fix `ST = stEager` automatically. Either way the
strategy phantom is **ignored** by the `RK = rkNone` body — there are no
`when ST ==` blocks on the bounded branch.

**Reserved-without-specialization clause for `stManual`**: `stEager` is
the only value with active method specialization in v5.0; all three
current retire-bearing sites are eager-retire-after-publish (per §3.5).
The `stManual` value is RESERVED for future batch-retire scenarios but
has NO in-tree specialized code path beyond the preserved
`when ST != stManual:` segments-counter branch.

**Naming convention** (unified end-to-end across this design doc):

- Internal enum values use the `st`-prefixed form (`stEager`,
  `stManual`), matching the project's convention for cardinality
  (`ccSingle` / `ccMulti`) and reclamation kind (`rkNone` / `rkEbr`).
- Public bare-symbol exports `Manual` and `Eager` are preserved via
  `const` aliases for ease of grep continuity.

### 3.2 Strategy phantom lift (runtime → compile-time)

**Source-incompat note from the nim-debra design (§3.2 of the upstream
design)**: Nim does NOT allow `static`-default values on type-level
generic parameters. This forces the constructor procs to use a
**proc-level static default** for `ST`, which Nim *does* allow:

```nim
proc initQueue*[T;
                ccProd, ccCons: static PinScopeCardinality;
                ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                RK: static ReclamationKind;
                N, P, C, S, MaxThreads: static int](
    ## RK = rkNone (bounded) overload — no manager arg.
    ## RK = rkEbr  (unbounded) overload — takes manager + handle.
    ## Both shapes share the `initQueue` name; Phase 3 picks whether
    ## to model as one proc with `when RK == ...` body or two overloads.
): Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]
```

The proc-level static default on `ST` is the **only** ergonomic
concession in v5.0.0. Every other phantom (`ccProd`, `ccCons`, `RK`)
MUST be specified by the caller — no defaults — because the operator
chose to "force explicit intent." `ST` keeps its default because
`DefaultDeallocationStrategy` is environment-derived
(`when defined(gcNone)`) and the caller usually does not want to
override the OS-derived default.

**Runtime `if` → compile-time `when` migration** (6 sites in the
unbounded `*` source files, verified): every `if self.strategy ==`
becomes `when ST ==`. See §3.5 for the per-site rewrites.

### 3.3 Cardinality phantom on queue + Consumer

Cardinality is exposed as static phantom parameters (`ccProd`,
`ccCons`) on the unified `Queue` generic per §3.0. The per-(queue
family)-equivalent fixed values are:

| Family equivalent | ccProd | ccCons | RK |
|---|---|---|---|
| Mupsic-equivalent (bounded MPSC) | ccMulti | ccSingle | rkNone |
| Sipmuc-equivalent (bounded SPMC) | ccSingle | ccMulti | rkNone |
| Mupmuc-equivalent (bounded MPMC) | ccMulti | ccMulti | rkNone |
| Sipsic-equivalent (bounded SPSC) | ccSingle | ccSingle | rkNone |
| UnboundedMupsic-equivalent | ccMulti | ccSingle | rkEbr |
| UnboundedSipmuc-equivalent | ccSingle | ccMulti | rkEbr |
| UnboundedMupmuc-equivalent | ccMulti | ccMulti | rkEbr |

(`UnboundedSipsic` is the separate type at §3.0.3; not in the table.)

**Per-(family) handle CC values** (fixed at the queue level, propagated
into `ThreadHandle[MaxThreads, CC]` fields on the queue, producer, and
consumer objects):

| Family equivalent | Producer handle CC | Consumer handle CC |
|---|---|---|
| Mupsic-equiv (ccMulti / ccSingle) | ccSingle (per-producer handle) | ccSingle (single consumer, handle on queue) |
| Sipmuc-equiv (ccSingle / ccMulti) | n/a (push is wait-free; no producer pin) | ccMulti (per-consumer handle on Consumer object) |
| Mupmuc-equiv (ccMulti / ccMulti) | ccSingle (per-producer handle) | ccMulti (per-consumer handle) |

(Bounded families do not carry handles; bounded queues have no debra
integration.)

**`Consumer*` and `Producer*` type signatures**: gain the full phantom
suite. The Consumer / Producer objects for the unbounded branch hold a
`queue: ptr Queue[T, ccProd, ccCons, ST, rkEbr, ...]` pointer; their
generic parameter list mirrors `Queue`'s.

```nim
type
  Consumer*[T; ccProd, ccCons: static PinScopeCardinality;
            ST: static DeallocationStrategy;
            N, P, C, S, MaxThreads: static int] = object
    queue: ptr Queue[T, ccProd, ccCons, ST, rkEbr, N, P, C, S, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads, ccCons]   ## consumer handle CC = ccCons
    when ccCons == ccMulti:
      localHead: int                            ## sipmuc-equiv local cache

  Producer*[T; ccProd, ccCons: static PinScopeCardinality;
            ST: static DeallocationStrategy;
            N, P, C, S, MaxThreads: static int] = object
    queue: ptr Queue[T, ccProd, ccCons, ST, rkEbr, N, P, C, S, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads, ccSingle]  ## producer handle is ccSingle
```

(`Consumer` / `Producer` are only defined for the `RK = rkEbr` branch;
bounded queues have no separate Consumer/Producer object types —
`push` / `pop` live directly on `Queue` with `when ccProd == ccMulti:`
specialization inside.)

**Two distinct cardinality axes (terminology guard)**: this design uses
`PinScopeCardinality` (`ccSingle`/`ccMulti`) on two structurally distinct
axes that share the same vocabulary; they MUST NOT be conflated.
**Axis A** is the queue-level `(ccProd, ccCons)` pair carried by the
unified `Queue` generic per §3.0; it describes retire-race semantics —
how many threads can occupy the producer or consumer role concurrently —
and drives the EBR retire-side selection (`retireOnCAS` vs
`retireOnPublish`) per §3.0.2. **Axis B** is the per-`ThreadHandle` `CC`
phantom introduced by nim-debra 0.8.0; it describes uncontested-pin
semantics on a single handle and is **always `ccSingle`** because a
`ThreadHandle` is owned by exactly one thread (the handle's pin
operation is single-threaded with respect to itself). The two axes are
independent: queue-level `ccProd=ccMulti` does NOT imply handle-level
`CC=ccMulti` (each producer thread carries its own `ccSingle` handle),
and conversely handle-level `CC=ccSingle` does NOT constrain the queue
to single-producer (many `ccSingle` handles co-exist on a `ccMulti`
queue). The per-family table above maps axis A to the axis-B value
carried in each field's handle type; the mapping is fixed per family,
not negotiated.

### 3.4 Public API impact

**ALL** typed call sites against the previous 8-family API surface
migrate. The §3.0 unification + no-alias rule means there is no
"transparent" subset. See §4 for the per-bucket impact count and §5
for the per-symbol migration table.

**Behaviorally compatible changes** (semantically identical after
migration):

- `if self.strategy ==` → `when ST ==`: monomorphizes per ST value at
  compile time; same runtime behavior; lower per-pop overhead.
- Mupsic-equivalent store-publish → CAS-with-expected=load:
  equivalent in single-consumer (the CAS cannot fail; degenerates to a
  store + retire with the same memory ordering).

### 3.5 PinnedScope migration of 5 withPin sites

Five sites total, all verified against the live source. Under v5.0.0
they live in the unified `Queue`'s push/pop bodies (within the
`when RK == rkEbr:` branch) instead of in the per-family
`unbounded_*.nim` files. The line citations below reference the
*original* v4.1 source for traceability; Phase 3 maps them to
positions in the unified body.

#### 3.5.1 Retire-bearing site 1: mupsic-equiv consumer pop (original `unbounded_mupsic.nim:337`)

Single-consumer, store-based publish. Migrates to `q.retireOnPublish`
per §3.0.2 (ccCons == ccSingle).

**Before** (`:337-377`, verified against v4.1):

```nim
self.handle.withPin:
  var seg = self.headSegment.load(moAcquire)
  while true:
    let tail = seg.tail.load(moAcquire)
    if seg.head < tail:
      if seg.committed[seg.head].load(moAcquire):
        result = some(seg.data[seg.head])
        inc seg.head
        discard self.itemCount.fetchSub(1, moRelaxed)
      break
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      break
    self.headSegment.store(nextSeg, moRelease)
    it.retire(cast[pointer](seg), segmentDestructor[S, T])
    if self.strategy != Manual:
      discard self.segments.fetchSub(1, moRelaxed)
    seg = nextSeg

if self.strategy == Eager:
  if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
    discard reclaimNow(self.handle)
```

**After** (inside `proc pop*[...](self: var Queue[T, ccMulti, ccSingle, ST, rkEbr, ...]) ...` body):

```nim
block:
  var scope = pinScope(unpinned(self.handle))  # PinnedScope[MaxThreads, ccSingle]
  var seg = self.headSegment.load(moAcquire)
  while true:
    let tail = seg.tail.load(moAcquire)
    if seg.head < tail:
      if seg.committed[seg.head].load(moAcquire):
        result = some(seg.data[seg.head])
        inc seg.head
        discard self.itemCount.fetchSub(1, moRelaxed)
      break
    let nextSeg = seg.next.load(moAcquire)
    if nextSeg == nil:
      break
    # Per-queue retireOnPublish wrapper (§3.0.2) routes to nim-debra's
    # store-publish primitive. The (γ) bounded-asymmetry guard fires
    # here: only defined for RK = rkEbr AND ccCons == ccSingle.
    self.retireOnPublish(
      scope, self.headSegment, nextSeg, segmentDestructor[S, T]
    )
    when ST != stManual:
      discard self.segments.fetchSub(1, moRelaxed)
    seg = nextSeg
  # scope.=destroy fires here.

when ST == stEager:
  if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
    discard reclaimNow(self.handle)
```

#### 3.5.2 Retire-bearing site 2: mupmuc-equiv Consumer.pop CAS (original `unbounded_mupmuc.nim:351`)

Multi-consumer CAS publish. Migrates to `q.retireOnCAS` per §3.0.2.

**Before** (`:351-416`, verified):

```nim
self.handle.withPin:
  var seg = self.queue.headSegment.load(moAcquire)
  var spins = InitialSpin
  while true:
    let tail = seg.tail.load(moAcquire)
    var prevIdx = seg.prevConsumerIdx.load(moAcquire)
    let mySlot = prevIdx + 1
    if mySlot >= tail:
      if mySlot < S and seg.tail.load(moAcquire) > mySlot:
        if not seg.committed[mySlot].load(moAcquire):
          break
        backoffOnRetry(spins)
        continue
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        break
      var expected = seg
      if self.queue.headSegment.compareExchangeStrong(
        expected, nextSeg, moAcquireRelease, moAcquire
      ):
        it.retire(cast[pointer](seg), segmentDestructor[S, T])
        if self.queue.strategy != Manual:
          discard self.queue.segments.fetchSub(1, moRelaxed)
        seg = nextSeg
      else:
        seg = expected
      backoffOnRetry(spins)
      continue
    if not seg.committed[mySlot].load(moAcquire):
      break
    if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
      result = some(seg.data[mySlot])
      discard self.queue.itemCount.fetchSub(1, moRelaxed)
      break

if self.queue.strategy == Eager:
  if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
    discard reclaimNow(self.handle)
```

**After** (inside `proc pop*[...](self: var Consumer[T, ccMulti, ccMulti, ST, ...])` body):

```nim
block:
  var scope = pinScope(unpinned(self.handle))  # PinnedScope[MaxThreads, ccMulti]
  var seg = self.queue.headSegment.load(moAcquire)
  var spins = InitialSpin
  while true:
    let tail = seg.tail.load(moAcquire)
    var prevIdx = seg.prevConsumerIdx.load(moAcquire)
    let mySlot = prevIdx + 1
    if mySlot >= tail:
      if mySlot < S and seg.tail.load(moAcquire) > mySlot:
        if not seg.committed[mySlot].load(moAcquire):
          break
        backoffOnRetry(spins)
        continue
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        break
      # Per-queue retireOnCAS wrapper (§3.0.2). The (γ) guard fires:
      # only defined for RK = rkEbr.
      if self.queue[].retireOnCAS(
        scope, self.queue.headSegment, seg, nextSeg, segmentDestructor[S, T]
      ):
        when ST != stManual:
          discard self.queue.segments.fetchSub(1, moRelaxed)
        seg = nextSeg
      else:
        seg = self.queue.headSegment.load(moAcquire)
      backoffOnRetry(spins)
      continue
    if not seg.committed[mySlot].load(moAcquire):
      break
    if seg.prevConsumerIdx.compareExchange(prevIdx, mySlot, moAcquire, moRelaxed):
      result = some(seg.data[mySlot])
      discard self.queue.itemCount.fetchSub(1, moRelaxed)
      break

when ST == stEager:
  if self.handle.advanceEvery(LockFreeQueuesAdvanceEvery):
    discard reclaimNow(self.handle)
```

**Subtle change**: the old code on CAS failure assigns `seg = expected`
(the value loaded by the failing compareExchangeStrong). `retireOnCAS`
returns a boolean only — it does not expose the load result. The
migration re-reads `self.queue.headSegment.load(moAcquire)` after the
failing CAS; this is one extra atomic load per CAS-failure path, which
is the *backoff* path anyway. Functionally equivalent. (Filed as Risk
5 in §8.)

#### 3.5.3 Retire-bearing site 3: sipmuc-equiv Consumer.pop CAS (original `unbounded_sipmuc.nim:299`)

Structurally identical to §3.5.2 — same pattern, with
`compareExchange` (weak) instead of `compareExchangeStrong`. Direct
migration to `q.retireOnCAS`. Omitted verbatim for brevity; same shape.

#### 3.5.4 Producer-push pin-only site 1 (original `unbounded_mupsic.nim:252`)

No retire. Pin-only — the pin prevents a consumer from reclaiming a
segment the producer is writing into.

**Before** (`:252-299`, verified):

```nim
self.handle.withPin:
  var spins = InitialSpin
  while true:
    var seg = self.queue.tailSegment.load(moAcquire)
    var tail = seg.tail.load(moAcquire)
    if tail >= S:
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        let newSeg = newSegment[S, T]()
        var expectedNext: ptr Segment[S, T] = nil
        if seg.next.compareExchange(expectedNext, newSeg, moRelease, moRelaxed):
          var expectedSeg = seg
          discard self.queue.tailSegment.compareExchange(
            expectedSeg, newSeg, moRelease, moRelaxed
          )
          discard self.queue.segments.fetchAdd(1, moRelaxed)
          continue
        else:
          freeAligned(newSeg)
          backoffOnRetry(spins)
          continue
      else:
        var expectedSeg = seg
        discard self.queue.tailSegment.compareExchange(
          expectedSeg, nextSeg, moRelease, moRelaxed
        )
        continue
    var expected = tail
    if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
      seg.data[tail] = item
      seg.committed[tail].store(true, moRelease)
      discard self.queue.itemCount.fetchAdd(1, moRelaxed)
      break
```

**After** (inside `proc push*[...](self: var Producer[T, ccMulti, ccSingle, ST, ...])` body):

```nim
block:
  var scope = pinScope(unpinned(self.handle))  # PinnedScope[MaxThreads, ccSingle]
  var spins = InitialSpin
  while true:
    var seg = self.queue.tailSegment.load(moAcquire)
    var tail = seg.tail.load(moAcquire)
    if tail >= S:
      let nextSeg = seg.next.load(moAcquire)
      if nextSeg == nil:
        let newSeg = newSegment[S, T]()
        var expectedNext: ptr Segment[S, T] = nil
        if seg.next.compareExchange(expectedNext, newSeg, moRelease, moRelaxed):
          var expectedSeg = seg
          discard self.queue.tailSegment.compareExchange(
            expectedSeg, newSeg, moRelease, moRelaxed
          )
          discard self.queue.segments.fetchAdd(1, moRelaxed)
          continue
        else:
          freeAligned(newSeg)
          backoffOnRetry(spins)
          continue
      else:
        var expectedSeg = seg
        discard self.queue.tailSegment.compareExchange(
          expectedSeg, nextSeg, moRelease, moRelaxed
        )
        continue
    var expected = tail
    if seg.tail.compareExchange(expected, tail + 1, moAcquire, moRelaxed):
      seg.data[tail] = item
      seg.committed[tail].store(true, moRelease)
      discard self.queue.itemCount.fetchAdd(1, moRelaxed)
      break
  # scope.=destroy fires here — destructor registered via
  # {.destructorTransition: PinnedScopeAlive -> PinnedScopeDestroyed.}
  # which typestates 0.9.0 accepts at every block-exit edge.
```

#### 3.5.5 Producer-push pin-only site 2 (original `unbounded_mupmuc.nim:268`)

Structurally identical to §3.5.4 — same migration shape, `ccSingle` CC,
no retire calls. Omitted verbatim.

#### 3.5.6 Pin-Claim Ordering invariant (back-reference)

The **Pin-Claim 6-Item Ordering** invariant lives in **nim-debra design
doc §3.4.0** as the authoritative location. Lockfreequeues upholds it
by routing through the per-queue wrappers in §3.0.2: the
mupmuc-equivalent and sipmuc-equivalent Consumer.pop CAS sites use
`q.retireOnCAS(...)`; the mupsic-equivalent consumer-side `headSegment`
advance uses `q.retireOnPublish(...)`. The wrappers preserve the
invariant because they delegate to the nim-debra primitive (which
encodes items 1–6 in its rotation chain). Phase 3 verifies the trace
per nim-debra §3.4.0 against the migrated code; any divergence is a
release blocker.

### 3.6 25-file `typestates/` scaffolding migration

(Unchanged from prior revision — the scaffolding files reference
`ThreadHandle` / `Pinned` / `EpochGuardContext` types and gain the CC
phantom. The Queue unification does not affect this surface; the
scaffolding is a teach/test layer separate from the production queue
code.)

Triage:

- **6 files require CC cascade**: `unbounded_mpmc_pop.nim`,
  `unbounded_mpmc_push.nim`, `unbounded_mpsc_pop.nim`,
  `unbounded_mpsc_push.nim`, `unbounded_spmc_pop.nim`,
  `unbounded_spmc_push.nim`.
- **2 files** (`unbounded_spsc_pop.nim`, `unbounded_spsc_push.nim`) have
  zero debra references — UNTOUCHED.
- **17 files** for bounded queue typestate machinery and slot_seq_n —
  UNTOUCHED.

Per-file LOC estimate: ~211 LOC across the 6 in-scope files (unchanged
from prior estimate).

**`spmc_push.nim` special case**: its local Base type carries
`strategy*: int` at `:22`. This is **removed** and the type gains the
`ST: static DeallocationStrategy` phantom matching the unified queue.
Test `tests/t_unbounded_spmc_push_typestate.nim` updates analogously.

### 3.7 Test migration

**All typed call sites migrate.** Verified by grep over `src/` +
`tests/`: 167 typed bindings + 141 init/new call sites, ~308 total.
Of those, `UnboundedSipsic` / `newUnboundedSipsic` sites stay
unchanged; the rest (~290+) all migrate to `Queue[T, ...]` form.

The migration is **mechanical** — every per-family constructor /
type-annotation has a single deterministic unified replacement (see §5
for the full per-symbol table). Phase 3 may use a `sed`-style script to
do the bulk conversion, with manual review of each file post-conversion.

**Typestate-bridging tests** (the 6 debra-aware
`tests/t_unbounded_*_typestate.nim` files): CC cascade applied per §3.6.
~92 references total.

**New test files**:

- `tests/t_queue_strategy_phantom.nim` — Strategy phantom monomorphization
  (`stManual` and `stEager`) × cardinality matrix (mupsic-equiv,
  sipmuc-equiv, mupmuc-equiv). Asserts both branches compile and
  segment-count semantics differ as expected.
- `tests/t_queue_cardinality_mismatch.nim` — compile-fail tests:
  - `var c: Consumer[..., ST=stManual]` cannot be constructed from
    `Queue[..., ST=stEager]`.
  - `getConsumer` on `ccCons=ccSingle` queue rejects `ccMulti` handle
    and vice versa.
- `tests/t_queue_bounded_no_retire.nim` — compile-fail: `q.retireOnCAS(...)`
  on a `Queue[..., RK=rkNone]` fails to compile (method-not-defined,
  per the §3.0.2 (γ) guard).

### 3.8 Avocado coordination plan

(Unchanged from prior revision in substance.) The 6 debra-aware
scaffolding files we touch overlap with what avocado is documented to
own; the 19 untouched files do not.

**Three coordination paths**, in order of operator preference:

1. **Pause + rebase** (preferred): avocado pauses β3+β4 work, lockfreequeues
   v5.0 ships, avocado rebases against the new CC-threaded scaffolding.
2. **Parallel + merge resolution**: avocado's β3+β4 branch continues; the
   v5.0 PR creates merge conflicts only on the 6 in-scope files.
   Resolution is mechanical (additive changes at non-overlapping syntactic
   positions).
3. **Defer the scaffolding migration to v5.1**: ship lockfreequeues
   v5.0 with only the production migrations. **Incompatible with
   operator directive "no deferrals, only correctness"** — kept here only
   for completeness.

A `lfq-pepper` message gates Phase 3 entry. Path 1 chosen if pepper
confirms avocado can pause; Path 2 otherwise.

## 4. Implementation Plan

**CRITICAL SAFETY NOTES FOR PHASE 3 IMPLEMENTATION**

1. **NO type aliases over `Queue`.** Operator decision 2026-05-17. Do
   not introduce `Mupsic` / `UnboundedMupsic` / etc. aliases as a
   "soft-landing" migration aid. The breaking change is intentional
   and the CHANGELOG migration table is the soft landing.
2. **`UnboundedSipsic` stays separate.** Do not fold it into `Queue`
   under any condition. See §3.0.3 for the rationale.
3. **`RK` has no default.** Callers MUST write `rkNone` or `rkEbr` at
   every `Queue[...]` instantiation. The verbosity is intentional.

### Re-derived migration impact (verified)

Counts from `grep -rE "\b(Mupsic|Sipmuc|Mupmuc|Sipsic|UnboundedMupsic|UnboundedSipmuc|UnboundedMupmuc|UnboundedSipsic)\["` over `src/` + `tests/`:

| Bucket | Count | Migration |
|---|---|---|
| Typed bindings of legacy queue names (incl. UnboundedSipsic, which is unchanged) | 167 | Subtract `UnboundedSipsic` bindings (~6 in `tests/t_unbounded_sipsic*.nim`); remaining ~161 all migrate to `Queue[T, ...]`. |
| Constructor call sites (init* / newUnbounded*) | 141 | Subtract `newUnboundedSipsic` (~5 in same files); remaining ~136 all migrate. |
| **Total migrated sites** | **~290+** | Mechanical conversion; no "compile unchanged" subset. |

Compared to the v4.2 framing's "~180 transparent + 12 migrate" estimate:
that was based on long-form aliases preserving the 4.1.x type names.
Under v5.0.0's no-alias rule the 180 transparent count is **0**; the
migration is fully pervasive.

### File-by-file change list

Estimated **~1100 LOC added/changed, ~400 LOC deleted** (net **+700**)
vs the prior v4.2 estimate of +640/-120 (net +520). The increase is
driven by the Queue body's `when RK == ...` ladder (which carries both
bounded and unbounded field layouts) and the per-method
`when RK == ...:` dispatch.

| # | File | Action | New LOC | Deleted LOC | Notes |
|---|---|---|---|---|---|
| 1 | `src/lockfreequeues/strategy.nim` | CREATE | 25 | 0 | Shared `DeallocationStrategy` enum. |
| 2 | `src/lockfreequeues/reclamation.nim` | CREATE | 15 | 0 | `ReclamationKind` enum. |
| 3 | `src/lockfreequeues/queue.nim` | CREATE | ~600 | 0 | Unified `Queue` generic + `Producer*` / `Consumer*` for the EBR branch + `initQueue` / `newQueue` constructors + `push` / `pop` / `getConsumer` / `getProducer` / `=destroy` with `when RK == ...:` ladders. |
| 4 | `src/lockfreequeues/mupsic.nim` | DELETE | 0 | ~260 | Bounded MPSC body folded into queue.nim. |
| 5 | `src/lockfreequeues/sipmuc.nim` | DELETE | 0 | ~260 | Bounded SPMC. |
| 6 | `src/lockfreequeues/mupmuc.nim` | DELETE | 0 | ~325 | Bounded MPMC. |
| 7 | `src/lockfreequeues/sipsic.nim` | DELETE | 0 | ~140 | Bounded SPSC. |
| 8 | `src/lockfreequeues/unbounded_mupsic.nim` | DELETE | 0 | ~430 | Unbounded MPSC folded into queue.nim. |
| 9 | `src/lockfreequeues/unbounded_sipmuc.nim` | DELETE | 0 | ~370 | Unbounded SPMC. |
| 10 | `src/lockfreequeues/unbounded_mupmuc.nim` | DELETE | 0 | ~440 | Unbounded MPMC. |
| 11 | `src/lockfreequeues/unbounded_sipsic.nim` | KEEP | 0 | 0 | UNCHANGED per §3.0.3. |
| 12 | `src/lockfreequeues.nim` (umbrella) | MODIFY | ~10 | ~20 | Re-exports `queue`, `strategy`, `reclamation`, `unbounded_sipsic`; removes the 7 deleted per-family re-exports. |
| 13 | `src/lockfreequeues/typestates/unbounded_mpsc_push.nim` | MODIFY | ~33 | ~10 | CC cascade. |
| 14 | `src/lockfreequeues/typestates/unbounded_mpsc_pop.nim` | MODIFY | ~43 | ~12 | CC cascade. |
| 15 | `src/lockfreequeues/typestates/unbounded_mpmc_push.nim` | MODIFY | ~33 | ~10 | CC cascade. |
| 16 | `src/lockfreequeues/typestates/unbounded_mpmc_pop.nim` | MODIFY | ~43 | ~12 | CC cascade. |
| 17 | `src/lockfreequeues/typestates/unbounded_spmc_push.nim` | MODIFY | ~24 | ~12 | CC cascade + Strategy phantom. |
| 18 | `src/lockfreequeues/typestates/unbounded_spmc_pop.nim` | MODIFY | ~36 | ~10 | CC cascade. |
| 19 | `tests/t_mupsic.nim` and 14 sibling per-family test files | MODIFY | ~600 (cumulative) | ~600 (cumulative) | Mechanical conversion of all typed bindings + constructor calls to `Queue[T, ...]` form. Per-file delta is roughly LOC-neutral; the new lines are longer (more generic params). |
| 20 | `tests/t_unbounded_sipsic.nim` | KEEP | 0 | 0 | UNCHANGED. |
| 21 | `tests/t_unbounded_*_typestate.nim` (6 files) | MODIFY | ~100 | ~30 | CC cascade. |
| 22 | `tests/t_queue_strategy_phantom.nim` | CREATE | ~150 | 0 | New phantom monomorphization test. |
| 23 | `tests/t_queue_cardinality_mismatch.nim` | CREATE | ~80 | 0 | New compile-fail tests. |
| 24 | `tests/t_queue_bounded_no_retire.nim` | CREATE | ~40 | 0 | New compile-fail test for the (γ) guard. |
| 25 | `examples/event_collector.nim` | MODIFY | ~5 | ~5 | Migrate constructor + type annotations. |
| 26 | `examples/job_scheduler.nim` | MODIFY | ~5 | ~5 | Migrate constructor + type annotations. |
| 27 | `lockfreequeues.nimble` | MODIFY | 2 | 2 | `version = "5.0.0"`; `requires "debra >= 0.8.0"`; `requires "typestates >= 0.9.0"`. |
| 28 | `CHANGELOG.md` | MODIFY | ~120 | 0 | `## [5.0.0]` section opening with BREAKING NOTICE block + migration table. |
| 29 | `docs/guide/core-concepts.md` | MODIFY | ~50 | ~50 | Rewrite to lead with unified `Queue` generic; per-family explanations become per-(ccProd, ccCons, RK) explanations. |
| 30 | `AGENTS.md` | MODIFY | ~30 | ~30 | Rework around the unified `Queue` model. |

**Phase 3 ordering** (dispatch within feature-implement):

1. (Phase 3a) Land typestates 0.9.0 in nimble + verify `nimble develop`
   resolves the new version.
2. (Phase 3b) Land nim-debra 0.8.0 similarly.
3. (Phase 3c) Create `strategy.nim` and `reclamation.nim`.
4. (Phase 3d) Author `queue.nim` — the unified generic + EBR branch
   bodies + bounded branch bodies + push/pop/getConsumer/getProducer.
   Smoke-compile a tiny fixture (`var q: Queue[int, ccMulti, ccSingle,
   stEager, rkNone, 16, 4, 0, 0, 0]`).
5. (Phase 3e) Bulk-convert tests + examples (sed-style); per-file manual
   review.
6. (Phase 3f) Delete the 7 per-family source files (steps 4-10 in the
   file table). Re-run `nimble test`.
7. (Phase 3g) Migrate the 6 typestate scaffolding files one at a time.
8. (Phase 3h) Author the 3 new test files
   (`t_queue_strategy_phantom.nim`, `t_queue_cardinality_mismatch.nim`,
   `t_queue_bounded_no_retire.nim`).
9. (Phase 3i) Run full matrix (`orc`, `arc`, `refc`, `cpp`,
   `nimEnforceLockFreeAtomics×2`). Run benchmarks under cold-state
   measurement protocol (per memory `thermal_throttling_validation`)
   to fingerprint any non-zero codegen delta on the bounded branch
   (see Risk 9 in §8).
10. (Phase 3j) CHANGELOG, version bump 4.1.0 → 5.0.0, tag, push.

## 5. API Surface (Public Declarations) + Migration Table

### `src/lockfreequeues/strategy.nim` (new)

```nim
type DeallocationStrategy* = enum
  stManual    ## Reserved for future batch-retire; no specialization in v5.0.
  stEager     ## Active in v5.0; per-pop best-effort `reclaimNow(handle)`.

const
  Manual* = stManual
  Eager*  = stEager

when defined(gcNone):
  const DefaultDeallocationStrategy* = stManual
else:
  const DefaultDeallocationStrategy* = stEager
```

### `src/lockfreequeues/reclamation.nim` (new)

```nim
type ReclamationKind* = enum
  rkNone   ## Bounded queues: no reclamation machinery.
  rkEbr    ## Unbounded queues: EBR via nim-debra.
```

### `src/lockfreequeues/queue.nim` (new — the canonical surface)

```nim
import ./strategy, ./reclamation
import debra
export DeallocationStrategy, ReclamationKind, Manual, Eager,
       stManual, stEager, rkNone, rkEbr, DefaultDeallocationStrategy

type
  Queue*[T;
         ccProd, ccCons: static PinScopeCardinality;
         ST: static DeallocationStrategy;
         RK: static ReclamationKind;
         N, P, C, S, MaxThreads: static int] = object
    when RK == rkNone:
      ## Bounded body (Vyukov-style seq counters). See §3.0 for field
      ## detail; the layout matches the existing per-family bounded
      ## queues' fields, gated by `when ccProd == ...:` / `when ccCons
      ## == ...:`.
      slots: array[N, Slot[T]]
      producerSeq: Atomic[int]
      consumerSeq: Atomic[int]
      when ccProd == ccMulti:
        producerHeads: array[P, Atomic[int]]
      when ccCons == ccMulti:
        consumerHeads: array[C, Atomic[int]]
    elif RK == rkEbr:
      ## Unbounded body (LCRQ-style segmented + debra reclamation).
      manager: ptr DebraManager[MaxThreads]
      headSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      tailSegment {.align: CacheLineBytes.}: Atomic[ptr Segment[S, T]]
      itemCount: Atomic[int]
      segments: Atomic[int]
      ownsManager: bool
      when ccProd == ccMulti: producerCount: Atomic[int]
      when ccCons == ccMulti: consumerCount: Atomic[int]
      when ccProd == ccMulti and ccCons == ccSingle:
        handle: ThreadHandle[MaxThreads, ccSingle]
      when ccCons == ccMulti:
        consumerHeadArray: array[MaxThreads, Atomic[int]]

  ## Producer / Consumer types only defined for the rkEbr branch.
  ## Bounded queues have no separate handle objects — push/pop live on Queue.
  Producer*[T; ccProd, ccCons: static PinScopeCardinality;
            ST: static DeallocationStrategy;
            N, P, C, S, MaxThreads: static int] = object
    queue: ptr Queue[T, ccProd, ccCons, ST, rkEbr, N, P, C, S, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads, ccSingle]

  Consumer*[T; ccProd, ccCons: static PinScopeCardinality;
            ST: static DeallocationStrategy;
            N, P, C, S, MaxThreads: static int] = object
    queue: ptr Queue[T, ccProd, ccCons, ST, rkEbr, N, P, C, S, MaxThreads]
    idx*: int
    handle: ThreadHandle[MaxThreads, ccCons]
    when ccCons == ccMulti: localHead: int

## Bounded constructor (RK = rkNone).
proc initQueue*[T;
                ccProd, ccCons: static PinScopeCardinality;
                ST: static DeallocationStrategy = DefaultDeallocationStrategy;
                N, P, C: static int](
): Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]

## Unbounded constructor (RK = rkEbr) — manager-owning + manager-borrow overloads.
proc newQueue*[T;
               ccProd, ccCons: static PinScopeCardinality;
               ST: static DeallocationStrategy = DefaultDeallocationStrategy;
               S, MaxThreads: static int](
    manager: ptr DebraManager[MaxThreads],
    handle: ThreadHandle[MaxThreads, ccCons]   ## consumer handle for mupsic-equiv
): Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]

proc newQueue*[T;
               ccProd, ccCons: static PinScopeCardinality;
               ST: static DeallocationStrategy = DefaultDeallocationStrategy;
               S, MaxThreads: static int](
): Queue[T, ccProd, ccCons, ST, rkEbr, 0, 0, 0, S, MaxThreads]

## push / pop / getConsumer / getProducer / =destroy — full signatures
## omitted here; bodies dispatch via `when RK == ...:` and
## `when ccProd / ccCons == ...:` ladders. Per-method shape follows the
## existing per-family proc signatures with the Queue generic-param list
## substituted.

## §3.0.2 wrappers — only defined for RK = rkEbr.
proc retireOnCAS*[T; ccProd, ccCons; ST; CC; N, P, C, S, MaxThreads; U](
    q: var Queue[T, ccProd, ccCons, ST, rkEbr, N, P, C, S, MaxThreads];
    scope: var PinnedScope[MaxThreads, CC];
    atomic: var Atomic[U]; expected, new: U;
    dtor: DestructorProc[U]
): bool

proc retireOnPublish*[T; ccProd; ST; CC; N, P, C, S, MaxThreads; U](
    q: var Queue[T, ccProd, ccSingle, ST, rkEbr, N, P, C, S, MaxThreads];
    scope: var PinnedScope[MaxThreads, CC];
    atomic: var Atomic[U]; new: U;
    dtor: DestructorProc[U]
)
```

### `src/lockfreequeues/unbounded_sipsic.nim` (unchanged)

```nim
type UnboundedSipsic*[S: static int, T] = object  # verified at :30
  ## Unchanged. Stays outside the unified Queue generic per §3.0.3.
  ...
proc newUnboundedSipsic*[S: static int, T](): UnboundedSipsic[S, T]  # :51, unchanged
```

### Migration table (for CHANGELOG; authoritative)

Every removed public symbol and its unified replacement:

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
| `var q = initMupsic[N, P, T]()` | `var q = initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()` |
| `var q = initSipmuc[N, C, T]()` | `var q = initQueue[T, ccSingle, ccMulti, stEager, N, 0, C]()` |
| `var q = initMupmuc[N, P, C, T]()` | `var q = initQueue[T, ccMulti, ccMulti, stEager, N, P, C]()` |
| `var q = initSipsic[N, T]()` | `var q = initQueue[T, ccSingle, ccSingle, stEager, N, 0, 0]()` |
| `var q = newUnboundedMupsic[S, T, MaxThreads](addr m, h)` | `var q = newQueue[T, ccMulti, ccSingle, stEager, S, MaxThreads](addr m, h)` |
| `var q = newUnboundedMupsic[S, T, MaxThreads](addr m, h, Manual)` | `var q = newQueue[T, ccMulti, ccSingle, stManual, S, MaxThreads](addr m, h)` |
| `var q = newUnboundedSipmuc[S, T, MaxThreads](addr m)` | `var q = newQueue[T, ccSingle, ccMulti, stEager, S, MaxThreads](addr m)` |
| `var q = newUnboundedMupmuc[S, T, MaxThreads](addr m)` | `var q = newQueue[T, ccMulti, ccMulti, stEager, S, MaxThreads](addr m)` |
| `var q = newUnboundedSipsic[S, T]()` | UNCHANGED — `var q = newUnboundedSipsic[S, T]()` |

CHANGELOG includes this table verbatim; the doc carries the
authoritative copy.

## 6. Test Plan

### 6.1 Behavioral correctness (regression suite)

The existing per-family behavioral tests in `tests/` migrate as-is
after the mechanical Queue conversion. Specifically the existing tests
remain authoritative for:

- Push/pop FIFO correctness (per-segment and across-segment, both
  bounded and unbounded).
- Segment retirement + reclamation under both `stManual` and `stEager`.
- Multi-segment growth via producer-driven `newSegment` allocation.
- Consumer-side CAS contention (mupmuc-equiv, sipmuc-equiv) under stress.
- `segmentCount` semantics (live count under Eager; peak-until-reclaim
  under Manual).
- Bounded queue full / empty / wraparound semantics.

Threaded suites (`*_threaded.nim`) verify multi-thread CAS-failure
backoff after the `seg = expected` → `seg = headSegment.load(...)`
re-read change.

### 6.2 Strategy phantom monomorphization

New test `tests/t_queue_strategy_phantom.nim`:

```nim
suite "Queue ST phantom monomorphization":
  test "stManual mupsic-equiv: pop on empty returns none, segmentCount peak":
    var mgr = initDebraManager[4]()
    let h = registerThread(mgr, ccSingle)
    var q = newQueue[int, ccMulti, ccSingle, stManual, 16, 4](addr mgr, h)
    var p = q.getProducer(registerThread(mgr, ccSingle))
    for i in 0 ..< 64: p.push(i)
    for _ in 0 ..< 64: discard q.pop()
    check q.segmentCount() >= 4  # stManual: peak count, no auto-reclaim
    discard reclaimNow(mgr)

  test "stEager mupsic-equiv: pop on empty, segmentCount drops":
    var mgr = initDebraManager[4]()
    let h = registerThread(mgr, ccSingle)
    var q = newQueue[int, ccMulti, ccSingle, stEager, 16, 4](addr mgr, h)
    # ... drain ... assert segmentCount drops after advanceEvery cadence.

  test "Default ST matches DefaultDeallocationStrategy":
    var mgr = initDebraManager[4]()
    let h = registerThread(mgr, ccSingle)
    var q = newQueue[int, ccMulti, ccSingle, S=DefaultDeallocationStrategy, 16, 4](addr mgr, h)
    when defined(gcNone):
      check ST(q) == stManual
    else:
      check ST(q) == stEager

  test "stManual + mupmuc-equiv with multi-consumer retire":
    var mgr = initDebraManager[8]()
    var q = newQueue[int, ccMulti, ccMulti, stManual, 16, 8](addr mgr)
    # ... 2 consumers, push 32, drain, assert no auto-reclaim.

  test "stEager + sipmuc-equiv with multi-consumer retire": ...
  test "stEager + mupmuc-equiv with multi-consumer retire": ...
```

### 6.3 Cardinality + bounded-asymmetry compile-fail

New tests `tests/t_queue_cardinality_mismatch.nim` and
`tests/t_queue_bounded_no_retire.nim`. Mechanism: typestates 0.9.0's
`should_fail/` convention OR a `nimble`-task that invokes `nim check`
on snippets expected to fail. Phase 3 chooses; either way the tests
assert:

1. `var c: Consumer[int, ccMulti, ccMulti, stManual, ...]` cannot be
   constructed from `var q = newQueue[int, ccMulti, ccMulti, stEager,
   ...](...)` (ST mismatch).
2. `getConsumer(q, registerThread(mgr, ccSingle))` on `q: Queue[...,
   ccCons=ccMulti, ...]` fails to compile (handle CC mismatch).
3. `getConsumer(q, registerThread(mgr, ccMulti))` on `q: Queue[...,
   ccCons=ccSingle, ...]` fails to compile.
4. **(γ) guard**: `q.retireOnCAS(scope, ...)` on `q: Queue[..., RK=rkNone, ...]`
   fails to compile with method-not-defined (per §3.0.2).
5. **(γ) guard**: `q.retireOnPublish(scope, ...)` on `q: Queue[...,
   ccCons=ccMulti, RK=rkEbr, ...]` fails to compile (only defined when
   ccCons == ccSingle).

### 6.4 Typestate-bridging regression

Six existing `tests/t_unbounded_*_typestate.nim` files (the 6
debra-aware ones) get their CC cascade applied per §3.7. All
assertions unchanged.

### 6.5 Full matrix

`nimble test` matrix (verified at `lockfreequeues.nimble`):

- `nim c --threads:on -r -f tests/test.nim` (default orc)
- `nim cpp --threads:on -r -f tests/test.nim`
- `nim c --mm:arc --threads:on -r -f tests/test.nim`
- `nim c --mm:refc --threads:on -r -f tests/test.nim`
- `nim c --mm:arc -d:nimEnforceLockFreeAtomics --threads:on -r -f tests/test.nim`
- `nim c --mm:orc -d:nimEnforceLockFreeAtomics --threads:on -r -f tests/test.nim`
- TSAN + ASAN under `clang` if `SANITIZE_THREADS != "no"` and
  `SANITIZE_ADDRESS != "no"` (gated env vars).

Plus `nimble examples` to verify the 2 unbounded example sites.

### 6.6 Bench delta (Risk 9)

The bounded branch of `Queue` is a new code path; the existing per-family
bounded queues' bench numbers may not transfer 1:1 to the unified
generic. Cold-state measurement (5-min idle, thermal pressure green —
per memory `thermal_throttling_validation`) on the existing
`benchmarks/nim/bench_*` files after migration. Any non-zero delta is
investigated pre-release, not deferred.

## 7. Open Questions Resolved

(Q6, Q8, Q9, Q13, Q15 from prior Phase 1.5 — resolutions carry forward
into v5.0.0 verbatim or with minor naming adjustments to reference
`ST`/`RK` instead of `Strategy`/`Cardinality`.)

### Q6: ST default const semantics under phantom

**RESOLVED**: Proc-level `static`-default on the `ST` generic parameter
of `initQueue` / `newQueue`. Type-level static-default does NOT work in
Nim. The runtime `strategy:` arg is REMOVED from all constructors (no
dual source of truth).

### Q8: lockfreequeues/typestates compatibility

**RESOLVED**: COMPOSE. The 25-file scaffolding remains a teach/test
surface separate from the unified `Queue` body. The 6 debra-aware files
migrate to CC-cascade alongside production; the 19 others stay untouched.

### Q9: Consumer construction consistency check

**RESOLVED**: Nim's native type system enforces it. `getConsumer` on
`Queue[..., ccCons=ccMulti, ...]` requires `handle: ThreadHandle[..,
ccMulti]` and returns `Consumer[.., ccCons=ccMulti, ..]`. ST mismatch
fails at Nim's type-mismatch level. Compile-fail test
(`t_queue_cardinality_mismatch.nim`) is purely defensive.

### Q13: Single-method vs split retireOnCAS variants

**RESOLVED**: SINGLE method (now the per-queue wrapper at §3.0.2). The
two retire-bearing CAS sites use the same `compareExchange → retire on
success` shape; the mupsic-equiv store-publish becomes a CAS-where-
expected=load that degenerates to a store in single-consumer.

### Q15: lockfreequeues/typestates ripple cost

**RESOLVED**: ~211 LOC across 6 scaffolding files + ~64 LOC across 6
typestate-bridging test files. Total scaffolding migration: ~275 LOC.
The Queue unification adds independent cost (~600 new LOC for the
unified body) on top.

## 8. Risk Register

| # | Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|---|
| 1 | **Avocado conflict on the 6 debra-aware scaffolding files**. | Medium | Medium | §3.8 coordination plan via pepper. Path 1 (pause + rebase) preferred. Phase 3 entry gated on pepper relay. |
| 2 | **v5.0.0 MAJOR adoption friction — every existing lockfreequeues user must migrate.** Every typed call site against the legacy 8 type names breaks; mechanical conversion is required. | High | Certain | §5 migration table is the authoritative artefact for adopters. Quality bar: "an existing 4.1.x user can mechanically sed their codebase from the table without re-reading the design doc." CHANGELOG opens with the BREAKING NOTICE block. Migration table is a release blocker. Consider a `migrations/v5.md` standalone doc Phase 3 may also write. |
| 3 | **25-file scaffolding migration cost surprises**. | Low | Medium | Phase 3g sequences the 6 files one-at-a-time. If a file balloons, escalate immediately. The 19 untouched files act as a hard upper bound on blast radius. |
| 4 | **ST default static type-param semantics**. The proc-level `static`-default mechanism (per Q6 resolution) is verified by the upstream nim-debra design, but the lockfreequeues use is independent. | Low | Low | Phase 3 starts with a one-file smoke fixture and verifies the proc-level default fires. If it does not (Nim regression), fall back to making the runtime `strategy:` arg an explicit proc-level non-static param that the proc body's `static:` cross-checks against the phantom. |
| 5 | **`retireOnCAS` discards the failure-load value** (per upstream nim-debra API in §3.4). The migration uses a re-read `self.queue.headSegment.load(moAcquire)` after a failing CAS. Adds one atomic load per CAS-failure path — on the backoff slow path. | Low | Low | Verified by inspection: the post-failure load runs only on the backoff path which already includes `backoffOnRetry(spins)`. If Phase 3 benchmarks show measurable regression, escalate to nim-debra 0.8.0 PATCH to change `retireOnCAS`'s `expected` to `var T`. |
| 6 | **Producer-push pin-only sites do nothing inside the pin**. A reviewer might question why a pin is needed at all. | Low | Low | The pin's purpose is documented at the call site: it prevents another consumer from reclaiming a segment the producer is about to write into. CHANGELOG + inline comments explain. |
| 7 | **CFG analyzer false-positive on the producer-push pin-only sites**. The new typestates 0.9.0 CFG analyzer walks pinned-scope-holding procs and rejects early-return without destructor firing. | Medium | Low | Per upstream typestates 0.9.0 design §3, `break` exits the loop but stays inside the surrounding `block:` (where `scope` lives), so the implicit `=destroy` at block-exit fires. Phase 3 smoke-tests this on one site and confirms before the other 4. |
| 8 | **`tryReclaim` symbol does not exist in nim-debra (0.7.x or 0.8.0)** — verified by grep. The 4.1.x source comments at `unbounded_mupsic.nim:55,58,365,376`, `unbounded_sipmuc.nim:57,60,325,335`, `unbounded_mupmuc.nim:53,56,386,396` reference `tryReclaim()` as a user-facing call but never invoke it; the actual API is `reclaimNow(handle)` / `reclaimNow(manager)`. **Line citations re-verified against v4.1 source on 2026-05-16**: 12 stale comment references total across the three files. | Low | Low | **v5.0 action** (in-scope, NOT deferred per `v4_3_no_post_release_deferral`): the 12 stale `tryReclaim` comments are obsolete because the three source files are **deleted** under v5.0.0 (per §4 file table rows 8–10) and folded into `queue.nim`. The new `queue.nim` uses `reclaimNow` only. No stale comments survive. |
| 9 | **Bounded queue performance regression from `when RK == rkNone:` ladder**. The unified `Queue` body's per-method dispatch adds a small layer of `when` indirection on the bounded code path. While `when` is compile-time, the generated machine code may differ subtly from the existing per-family bounded queues' codegen (e.g., different inlining decisions, different register allocation under the unified type's larger object size). | Medium | Medium | Phase 3i cold-state benchmark of all bounded code paths against v4.1 baselines. Any non-zero delta investigated. If a regression emerges, mitigations include: (a) `{.inline.}` or `{.codegenDecl.}` annotations on the hot push/pop paths; (b) splitting the bounded body into a separate `Queue` overload via `when RK == rkNone:` at the *type* level (Phase 3 last-resort). Not deferring to v5.1 per the operator's "no post-release deferral" rule. |
| 10 | **Generic-parameter list verbosity at call sites**. `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]` is 10 params; user code becomes line-noise. | Medium | High | Mitigations: (a) §3.0.4 optional smart-constructor procs (Phase 3 decides per-need); (b) CHANGELOG migration table uses `_` placeholder convention (Phase 3 picks `0` or a `const _ = 0`); (c) `docs/guide/core-concepts.md` rewrite leads with the most common (mupsic-equiv, mupmuc-equiv) instantiations as worked examples. |

## 9. Release Checklist

Pre-merge:

- [ ] `src/lockfreequeues/strategy.nim` exists; consolidates `DeallocationStrategy`.
- [ ] `src/lockfreequeues/reclamation.nim` exists; declares `ReclamationKind`.
- [ ] `src/lockfreequeues/queue.nim` exists; declares unified `Queue` generic
      with `when RK == rkNone:` (bounded) and `when RK == rkEbr:` (unbounded)
      field branches; declares `Producer*` / `Consumer*` for the EBR branch;
      declares `initQueue` / `newQueue` constructors; declares push / pop /
      getConsumer / getProducer / =destroy.
- [ ] `src/lockfreequeues/{mupsic,sipmuc,mupmuc,sipsic,unbounded_mupsic,
      unbounded_sipmuc,unbounded_mupmuc}.nim` files DELETED. Verify:
      `ls src/lockfreequeues/` shows only `queue.nim`, `strategy.nim`,
      `reclamation.nim`, `unbounded_sipsic.nim`, `atomic_dsl.nim`,
      `backoff.nim`, `exceptions.nim`, `internal/`, `typestates/`,
      `typestates.nim`.
- [ ] `src/lockfreequeues/unbounded_sipsic.nim` UNCHANGED. Verify:
      `git diff master -- src/lockfreequeues/unbounded_sipsic.nim` empty.
- [ ] `Queue` generic carries `T`, `ccProd`, `ccCons`, `ST`, `RK`, `N`, `P`,
      `C`, `S`, `MaxThreads` per §3.0; `Consumer*` and `Producer*` mirror
      shape minus `RK` (always rkEbr).
- [ ] No `strategy: DeallocationStrategy` field anywhere (verify:
      `grep -n "strategy:" src/lockfreequeues/*.nim` returns nothing).
- [ ] All 5 withPin sites migrated to `PinnedScope`; no remaining `withPin`
      usage (verify: `grep -rn withPin src/lockfreequeues/` returns zero hits).
- [ ] All 6 runtime `if self.strategy` / `if self.queue.strategy` branches
      flipped to `when ST` in the new `queue.nim` body.
- [ ] 6 typestate scaffolding files migrated to CC cascade.
- [ ] 19 typestate scaffolding files unchanged.
- [ ] All ~290+ typed call sites in `tests/` + `examples/` migrated to
      `Queue[T, ...]` form. `UnboundedSipsic` call sites unchanged (~10 sites
      in `tests/t_unbounded_sipsic*.nim`).
- [ ] New `t_queue_strategy_phantom.nim` passes.
- [ ] New `t_queue_cardinality_mismatch.nim` compile-fail tests verify per §6.3.
- [ ] New `t_queue_bounded_no_retire.nim` compile-fail test verifies the (γ)
      guard per §6.3.
- [ ] Full `nimble test` matrix green (orc + arc + refc + cpp +
      `nimEnforceLockFreeAtomics`×2).
- [ ] `nimble examples` green (2 examples).
- [ ] Bench delta capture green (Risk 9 — bounded path codegen vs v4.1
      baseline; cold-state measurement protocol).
- [ ] `nimble.lock` updated.
- [ ] `lockfreequeues.nimble`: `version = "5.0.0"`; requires `typestates
      >= 0.9.0`; requires `debra >= 0.8.0`.
- [ ] CHANGELOG `## [5.0.0] - 2026-MM-DD` section under `## [Unreleased]`
      rollover OPENS WITH THE **BREAKING NOTICE** BLOCK (§2.5 template) and
      includes the FULL migration table (§5). This is a release blocker.
- [ ] `docs/guide/core-concepts.md` reworked to lead with the unified
      `Queue` generic.
- [ ] `AGENTS.md` reworked to match.

Cut + push:

- [ ] Cut tag `v5.0.0` on `master` (or operator's preferred branch).
- [ ] Push to origin.
- [ ] If `nimble publish` is in use, publish to the package index;
      otherwise update the project's `nimble-packages` entry.

---

# END DESIGN DOCUMENT
