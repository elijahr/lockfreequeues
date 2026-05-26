# v5.0.0 cascade migration mapping (Task D2)

> **Historical artifact.** This document describes the pre-3.3.11-B
> 10-param unified Queue shape. The canonical reference for the
> shipped v5.0.0 surface is
> [`3.3.11-B-final-shape.md`](3.3.11-B-final-shape.md). Cross-reference
> any "After" form below against that document before relying on it.

**Worktree:** `~/Development/worktrees/lfq-v5.0.0-wave/lockfreequeues-track-D-early/`
**Branch:** `feat/v5.0.0-impl-track-D-early`
**Inventory commit:** `ad70f69` (`docs/v5.0.0-migration/cascade-inventory.md`)
**Authoritative source:** Doc C §5 "Migration table" (lines 1449-1474 of `design-strategy-cardinality-phantoms-v4.2-20260516.md`)
**Mapping date:** 2026-05-17

This artifact gives, for every legacy queue-family symbol inventoried in D1, its concrete `Queue[...]` replacement. Every "After" form is quoted verbatim from Doc C §5 — Doc C is the single source of truth; if any row below disagrees with Doc C, Doc C wins.

---

## 1. Type-form mapping (typed bindings)

Per Doc C §5 (lines 1455-1462), the seven collapsing type families map as follows. **The first generic parameter of `Queue` is the payload type `T`** (NOT capacity `N`), differing from the legacy `Mupsic[N, P, T]` order.

| Legacy symbol | Replacement `Queue[...]` | Cardinality | Reclamation | Strategy default |
|---|---|---|---|---|
| `Mupsic[N, P, T]` | `Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]` | M-P / S-C | rkNone | stEager |
| `Sipmuc[N, C, T]` | `Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0]` | S-P / M-C | rkNone | stEager |
| `Mupmuc[N, P, C, T]` | `Queue[T, ccMulti, ccMulti, stEager, rkNone, N, P, C, 0, 0]` | M-P / M-C | rkNone | stEager |
| `Sipsic[N, T]` | `Queue[T, ccSingle, ccSingle, stEager, rkNone, N, 0, 0, 0, 0]` | S-P / S-C | rkNone | stEager |
| `UnboundedMupsic[S, T, MaxThreads]` | `Queue[T, ccMulti, ccSingle, stEager, rkEbr, 0, 0, 0, S, MaxThreads]` | M-P / S-C | rkEbr | stEager |
| `UnboundedSipmuc[S, T, MaxThreads]` | `Queue[T, ccSingle, ccMulti, stEager, rkEbr, 0, 0, 0, S, MaxThreads]` | S-P / M-C | rkEbr | stEager |
| `UnboundedMupmuc[S, T, MaxThreads]` | `Queue[T, ccMulti, ccMulti, stEager, rkEbr, 0, 0, 0, S, MaxThreads]` | M-P / M-C | rkEbr | stEager |
| **`UnboundedSipsic[S, T]`** | **UNCHANGED — `UnboundedSipsic[S, T]`** (Doc C §3.0.3 carve-out) | S-P / S-C | (its own RK) | (its own ST) |

**`Queue` generic parameter list (canonical order, Doc C §3.0):**

```
Queue[T,                                   # payload type
      ccProd: static PinScopeCardinality,  # producer cardinality
      ccCons: static PinScopeCardinality,  # consumer cardinality
      ST: static DeallocationStrategy,     # rkEbr strategy phantom (ignored when rkNone)
      RK: static ReclamationKind,          # rkNone | rkEbr
      N: static int,                       # bounded capacity (rkNone) or 0 (rkEbr)
      P: static int,                       # bounded producer count (Mupsic/Mupmuc) or 0
      C: static int,                       # bounded consumer count (Sipmuc/Mupmuc) or 0
      S: static int,                       # rkEbr segment capacity or 0 (rkNone)
      MaxThreads: static int]              # rkEbr thread limit or 0 (rkNone)
```

Bounded families set `S = 0, MaxThreads = 0`. Unbounded families set `N = 0, P = 0, C = 0`.

**Cardinality phantoms (`ccProd`, `ccCons`):** the legacy "Mu/Si" prefix encodes producer cardinality (Mu = `ccMulti`, Si = `ccSingle`); the "mu/si" suffix encodes consumer cardinality. So Mupsic = MultiProducer + SingleConsumer = `ccMulti, ccSingle`. Sipsic = SingleProducer + SingleConsumer = `ccSingle, ccSingle`. Verified row-by-row against Doc C §3.3 cardinality phantom table.

---

## 2. Constructor mapping

Per Doc C §5 (lines 1463-1471). Bounded uses `initQueue` (no params at call site); unbounded uses `newQueue` (passes the manager pointer and optional handle).

### 2.1 Bounded constructors (`initQueue`)

| Legacy call | Replacement |
|---|---|
| `initMupsic[N, P, T]()` | `initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()` |
| `initSipmuc[N, C, T]()` | `initQueue[T, ccSingle, ccMulti, stEager, N, 0, C]()` |
| `initMupmuc[N, P, C, T]()` | `initQueue[T, ccMulti, ccMulti, stEager, N, P, C]()` |
| `initSipsic[N, T]()` | `initQueue[T, ccSingle, ccSingle, stEager, N, 0, 0]()` |

Bounded `initQueue` does NOT take `RK` (always `rkNone`) or `S`/`MaxThreads` (always 0). Its 7-param generic head is `[T, ccProd, ccCons, ST, N, P, C]`. The constructor internally specializes the full 10-param `Queue` form with `rkNone, S=0, MaxThreads=0`.

### 2.2 Unbounded constructors (`newQueue`)

| Legacy call | Replacement |
|---|---|
| `newUnboundedMupsic[S, T, MaxThreads](addr m, h)` | `newQueue[T, ccMulti, ccSingle, stEager, S, MaxThreads](addr m, h)` |
| `newUnboundedMupsic[S, T, MaxThreads](addr m, h, Manual)` | `newQueue[T, ccMulti, ccSingle, stManual, S, MaxThreads](addr m, h)` |
| `newUnboundedSipmuc[S, T, MaxThreads](addr m)` | `newQueue[T, ccSingle, ccMulti, stEager, S, MaxThreads](addr m)` |
| `newUnboundedMupmuc[S, T, MaxThreads](addr m)` | `newQueue[T, ccMulti, ccMulti, stEager, S, MaxThreads](addr m)` |
| **`newUnboundedSipsic[S, T]()`** | **UNCHANGED — `newUnboundedSipsic[S, T]()`** (carve-out) |

Notes:
1. The runtime `Manual` enum value moves to a compile-time phantom `stManual` in the constructor's `ST` parameter position (Doc C §3.2).
2. `Mupsic`-equiv unbounded carries a `handle` argument (single-consumer); `Sipmuc`-equiv and `Mupmuc`-equiv do not (per-consumer handles obtained later via `getConsumer`).
3. `newQueue` overloads dispatch on whether the handle arg is present (Doc C §3.0 / impl plan §E2 Step 1).
4. Default `ST = DefaultDeallocationStrategy` (= `stEager`) appears in the proc signature; explicit `stManual` (or `stEager`) is required only when the caller wants non-default behavior.

---

## 3. Module-import mapping

Per impl plan §D2 Step 2.

| Legacy import | Replacement |
|---|---|
| `import lockfreequeues/mupsic` | REMOVE (superseded by `lockfreequeues/queue`) |
| `import lockfreequeues/sipmuc` | REMOVE |
| `import lockfreequeues/mupmuc` | REMOVE |
| `import lockfreequeues/sipsic` | REMOVE |
| `import lockfreequeues/unbounded_mupsic` | REMOVE |
| `import lockfreequeues/unbounded_sipmuc` | REMOVE |
| `import lockfreequeues/unbounded_mupmuc` | REMOVE |
| `import lockfreequeues/unbounded_sipsic` | KEEP (carve-out — module still exists) |

Net per-file consumer-side replacement (after umbrella re-exports stabilize per D3.1):
```nim
import lockfreequeues  # umbrella; re-exports queue + unbounded_sipsic + strategy + reclamation
```

Or, for fine-grained imports inside the library itself:
```nim
import lockfreequeues/[queue, strategy, reclamation, unbounded_sipsic]
```

---

## 4. Per-cluster operation classification

For each cluster from D1, the dominant mechanical operation:

| Cluster | Sites | Operation | Notes |
|---|---:|---|---|
| `src/lockfreequeues/{mupsic,sipmuc,mupmuc,sipsic,unbounded_*}.nim` (7 files) | 121 | DELETE | Content collapsed into `queue.nim` (Track A1/A2) and unbounded body (Track E2). |
| `src/lockfreequeues/unbounded_sipsic.nim` | 0 | LEAVE-ALONE | C1 regression verifies (Doc C §3.0.3). |
| `src/lockfreequeues.nim` (umbrella) | 1 import line | RE-PARAMETERIZE | Replace 8 per-family imports with `[queue, strategy, reclamation, unbounded_sipsic]`. Track D3.1. |
| `src/lockfreequeues/typestates/*.nim` | 9 | RENAME / COMMENT-UPDATE | 6 in-scope unbounded scaffolding files = type-form rewrite (Track E4); 3 are comment-only references. |
| `tests/t_{mupsic,sipmuc,mupmuc,sipsic}{,_threaded}.nim` | bounded subset | RENAME + RE-PARAMETERIZE | Track B2 owns. Rename to `t_queue_bounded_{mupsic,sipmuc,mupmuc,sipsic}.nim` (or similar) and rewrite ctor + typed-binding sites. |
| `tests/t_unbounded_{mupsic,sipmuc,mupmuc}{,_threaded}.nim` | unbounded subset | RENAME + RE-PARAMETERIZE | Track E3 owns. Analogous rename + rewrite. |
| `tests/t_unbounded_{mupmc,mpsc,spmc}_{pop,push}_typestate.nim` (6 files per Doc C §3.6) | typestate subset | CC CASCADE | Track E4. Largely about CC parameter propagation; family-symbol rewrites incidental. |
| `tests/t_unbounded_sipsic{,_threaded,_lockfree_check,_lockfree_types}.nim` | 0 | LEAVE-ALONE | Carve-out. |
| `examples/{mupsic,sipmuc,mupmuc,sipsic}.nim` | 8 (2/file) | RENAME + RE-PARAMETERIZE | Track D3.5. Rename to `queue_bounded_*.nim` (TBD per implementer); rewrite ctor + typed sites. |
| `examples/{audio_buffer,event_collector,job_scheduler,task_fanout}.nim` | 4 (1/file) | RE-PARAMETERIZE | Track D3.5. In-place rewrite; no rename. |
| `benchmarks/nim/bench_{spsc,mpsc,mpmc,unbounded,latency}.nim` | 45 | RE-PARAMETERIZE | Track D3.6. Rewrite per the type-form + ctor mapping. |
| `benchmarks/nim/adapters/lockfreequeues_{mupsic,sipmuc,mupmuc,sipsic}_adapter.nim` | 15 | CONSOLIDATE | Track D3.6.5 commit 1: merge into `benchmarks/nim/adapters/queue_bounded_adapter.nim` parameterized over `ccProd, ccCons, ST, N, P, C`. |
| `benchmarks/nim/adapters/lockfreequeues_unbounded_{mupsic,sipmuc,mupmuc}_adapter.nim` | 8 | CONSOLIDATE | Track D3.6.5 commit 2: merge into `benchmarks/nim/adapters/queue_unbounded_adapter.nim` parameterized over `ccProd, ccCons, ST, S, MaxThreads`. |
| `benchmarks/nim/adapters/lockfreequeues_unbounded_sipsic_adapter.nim` | 0 | LEAVE-ALONE | Carve-out. |
| `benchmarks/nim/tests/t_adapter_{sipsic,mupmuc,mupsic,sipmuc}.nim` + unbounded variants | 4 | CONSOLIDATE | Track D3.6.5: replace 6 with `t_adapter_queue_bounded.nim` + `t_adapter_queue_unbounded.nim`. KEEP `t_adapter_lockfreequeues_unbounded_sipsic.nim`. |
| `docs/api/{mupsic,sipmuc,mupmuc,sipsic,unbounded_mupsic,unbounded_sipmuc,unbounded_mupmuc}.md` | 13 | DELETE | Track F2 authors single `queue.md`. |
| `docs/api/unbounded_sipsic.md` | 0 | LEAVE-ALONE | Carve-out KEEP. |
| `docs/api/index.md` | 1 | UPDATE | Replace 7 per-family ToC entries with `queue.md` + `unbounded_sipsic.md`. Track F2. |
| `docs/guide/{core-concepts,getting-started,memory-management,performance-tuning,bounded-vs-unbounded,safety-model,examples}.md` | 25 | REWRITE | Track F2. Prose + code-example updates. |
| `docs/plans/2025-11-30-*.md` (historical) | 35 | LEAVE-ALONE (recommended) | Historical design artifact. Surface to pepper for confirmation. |
| `docs/index.md` + top-level | 2 | UPDATE | Track F2. |

---

## 5. Special cases and gotchas

### 5.1 Parameter-order reversal

Legacy: `Mupsic[N, P, T]` puts capacity first, type last.
New: `Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]` puts type FIRST.

Mechanical sed must rewrite parameter order, not just substitute names. See impl plan §D3 Step 1 for the sed template; multi-line generic instantiations require manual handling.

### 5.2 `stManual` vs constructor argument

Legacy `newUnboundedMupsic[S, T, MaxThreads](addr m, h, Manual)` passes `Manual` as the THIRD runtime argument.
New `newQueue[T, ccMulti, ccSingle, stManual, S, MaxThreads](addr m, h)` passes `stManual` as a compile-time generic parameter; the runtime argument list shrinks by one.

Sed cannot handle this transformation correctly; D3 implementer must spot-check every `newUnbounded*(..., Manual)` call site and migrate by hand.

### 5.3 5 lines with combined typed + ctor on one line

D1 noted 5 lines like `let q: Mupsic[N, P, T] = initMupsic[N, P, T]()`. After migration:
```nim
let q: Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0] =
       initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()
```

The line length grows substantially; consider type aliases at the test or example level for readability (Doc C §3.0.4 mentions optional ergonomic constructor shorthands — Phase 3 decision deferred; D2 mapping does NOT pre-judge).

### 5.4 Comment-only family references

Inventory noted 3 typestate files (`mpmc_push.nim:51`, `mpsc_push.nim:54`, `spmc_push.nim:57`) with family names in doc comments. Mechanical sed rewrites these to `Queue[T,...,N,P,C,0,0]` references, which makes the comment less readable. D3 implementer should manually rewrite these comments to refer to the unified `Queue` generic with the appropriate cardinality combo.

### 5.5 `UnboundedSipsic` parallel constructor preserved

`newUnboundedSipsic[S, T]()` keeps its current signature unchanged. It does NOT migrate to `newQueue`. Doc C §3.0.3: "UnboundedSipsic stays separate (option (a) keep-separate)." Verified against Doc C §5 line 1471: `var q = newUnboundedSipsic[S, T]()` → `UNCHANGED`.

### 5.6 Bounded `initSipsic` has no P or C

`initSipsic[N, T]` has only `N` and `T`. The migrated form `initQueue[T, ccSingle, ccSingle, stEager, N, 0, 0]()` passes `0` for both `P` and `C`. (Bounded-asymmetry guard γ per Doc C §3.0.2 likely fires here; consult Doc C if `0` is the right sentinel vs `1`.)

---

## 6. Mechanical batch ordering (recap from impl plan §D2 Step 3)

The mapping above feeds Track D3's 7 batches:

1. **D3.1** — `src/lockfreequeues.nim` umbrella (after A2). 1 commit.
2. **D3.2** — `tests/test.nim` test-inventory (after B2). 1 commit.
3. **D3.3** — bounded tests (Track B2 internal — D3 no-op).
4. **D3.4** — unbounded tests (Track E3 internal — D3 no-op).
5. **D3.5** — `examples/` (after B1 for bounded, after E2 for unbounded). 4-8 commits.
6. **D3.6** — `benchmarks/nim/bench_*.nim` (bounded blocks B3 parity; unbounded after E2). 4 commits.
7. **D3.6.5** — `benchmarks/nim/adapters/` consolidation. 3 commits (bounded adapter, unbounded adapter, README).
8. **D3.7** — docs (Track F2 internal — D3 no-op).

D-late-bounded (sibling Manager) owns D3.1, D3.2, D3.5 bounded subset, D3.6 bounded subset, D3.6.5. D-late-unbounded (later sibling) picks up unbounded subsets after E2 lands.

---

## 7. Verification (definition of done)

- [x] Every D1-inventoried site has a target form (the 7 type families + 7 constructors + UnboundedSipsic carve-out exhaust the legacy symbol set).
- [x] No site is classified "Phase 3 decides" — every site has a concrete target.
- [x] `UnboundedSipsic` carve-out documented explicitly (§5.5).
- [x] Cited Doc C §5 row-by-row (Table 1, Table 2 above are verbatim from Doc C lines 1455-1471 with no rephrasing).
- [x] Module-import mapping covered (§3).
- [x] Per-cluster operation classified (§4).

---

## Appendix A: Doc C §5 source quote (for fact-check audit)

The Doc C §5 migration table quoted verbatim (Doc C lines 1453-1471):

```
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
```

Tables in §1 and §2 of this artifact reproduce every "After" form verbatim. If any divergence is later detected, Doc C is authoritative and this artifact must be amended.
