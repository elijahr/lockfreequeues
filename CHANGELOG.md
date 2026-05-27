# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(No entries yet — post-5.0.0 work lands here.)

## [5.0.0] - 2026-05-25

What was developed under the v4.2.0 and v4.3.0 banners ships for the
first time as v5.0.0. Neither v4.2.0 nor v4.3.0 was tagged or merged to
`devel`; both branches are abandoned in place (`feat/v4.2.0-bench-tightening`
and `feat/v4.3-task-14` remain on the remote as audit-trail artifacts and
are NOT carried forward as tags). The substantive work from both windows
is consolidated into v5.0.0 below, deduplicated against the unified Queue
reframe and against each other.

> **3.3.11-B reshape note (final v5.0.0 surface).** The original
> v5.0.0 plan landed a single unified
> `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]` (10
> params) plus a standalone `UnboundedSipsic[S, T]`. Phase 3.3.11-B
> reshaped that further:
>
> - **Bounded surface** split into a dedicated
>   `BQueue[T, ccProd, ccCons, N, P, C]` (6 params, no debra, no
>   `RK`/`ST`/`S`/`MaxThreads`).
> - **Unbounded surface** became
>   `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` (also 6 params).
>   The `(ccSingle, ccSingle)` arm of `Queue` absorbs the standalone
>   `UnboundedSipsic` body verbatim (debra-free, committed-flag
>   protocol). The standalone `UnboundedSipsic` module is deleted.
> - **Smart constructors** collapse from 11 family-prefixed entry
>   points to two generic ones (`newBQueue`, `newQueue`) plus
>   family-named thin wrappers (`newSipsicQueue`, `newMupsicQueue`,
>   `newSipmucQueue`, `newMupmucQueue`, `newUnboundedSipsicQueue`,
>   `newUnboundedMupsicQueue`, `newUnboundedSipmucQueue`,
>   `newUnboundedMupmucQueue`) retained as ergonomic aliases.
> - **Runtime `InvalidCallDefect` traps** (6 cardinality-illegal
>   call sites in the old unified Queue) lifted to compile-time
>   `{.error.}` overloads with user-visible-alias-only diagnostic
>   strings (M5 R9 gate).
> - **Middle-axis typestates landed in 3.3.11-B.4.1.6 (Bundle F).**
>   Lifecycle (`BQueueInit -> BQueueDestroyed` on `BQueue`;
>   `QueueInit -> QueueDestroyed` on `Queue`) and Claim-state
>   (`Unclaimed -> ProducerClaimed | ConsumerClaimed | BothClaimed`
>   on view types) ship under a REVISED design relative to the
>   original brief — see the "Bundle F revised design" section
>   below for the Wall 1 / Wall 2 / Wall 3 deviations.
>
> The canonical reference for the current surface is this CHANGELOG
> entry plus `docs/migration.md`.
>
> **Worked example — primary surface (3.3.11-B / M7 lock).** For new
> code, prefer the two generic constructors:
>
> ```nim
> import lockfreequeues
>
> # Bounded mupsic-equivalent (multi-producer, single-consumer):
> var q1 = newBQueue[int, ccMulti, ccSingle, 8, 4, 0]()
> let p1 = q1.getProducer()
> discard p1.push(42)
> discard q1.pop()                 # SPSC pop on single-consumer side
>
> # Unbounded mupmuc-equivalent (multi-producer, multi-consumer).
> # Each operating thread attaches before push/pop: debra thread
> # registration happens at attach time, not at construction.
> var q2 = newQueue(Queue[int, ccMulti, ccMulti, stEager, 64, 8])
> var p2 = q2.getProducer()
> p2.attach()                      # registers this thread; may raise
>                                  #   DebraRegistrationError
> var c2 = q2.getConsumer()
> c2.attach()
> p2.push(99)
> discard c2.pop()
> ```
>
> The family-named thin-wrappers (`newMupsicQueue`,
> `newUnboundedMupmucQueue`, …) stay for grep continuity with the
> v3.x/v4.x naming and to minimize churn in downstream call sites
> and benchmark adapters. For new code, prefer the two generic
> constructors above. Both styles compile to the same underlying
> type; the wrappers are pure ergonomic aliases.
>
> **Bundle F revised design (3.3.11-B.4.1.6).** The original Bundle
> F brief called for (a) self-loop `{.transition.}` pragmas on every
> state-preserving op to keep the queue value in `QueueInit` across
> push/pop and (b) a two-type alias dispatch (`BQueueProducer =
> when ccProd is ccMulti: BQueueProducerMulti else:
> BQueueProducerSingle`) so Claim-state attached only on the multi
> side. A pre-implementation probe step (B.4.1.5) empirically
> validated revised patterns against typestates v0.9.3:
>
> - ** — no self-loop transitions.** State-preserving
>   methods (`push`, `pop`, `getProducer`, `getConsumer`, `attach`,
>   `detach`, batch variants) declare NO `{.transition.}` pragma.
>   The typestate verifier accepts same-module non-transition procs
>   as state-preserving operations that mutate runtime fields
>   without changing the static typestate. Self-loop transitions
>   would be rejected by `validateTransitionsRespectInitialTerminal`
>   in the typestates parser. Terminal transitions are emitted
>   exclusively by `=destroy` via `destructorTransition`, mirroring
>   nim-debra's `pinned_scope.nim:178-180` verbatim.
>
> - ** — single object type with internal `when` switch.**
>   `BQueueProducer` / `BQueueConsumer` / `QueueProducer` /
>   `QueueConsumer` are single user-facing object types per view
>   (no Multi/Single split). The optional `claimed: bool` field
>   exists only under `when ccProd == ccMulti:` (or `ccCons ==
>   ccMulti` for consumers). The typestate attaches uniformly; the
>   ccSingle path has the typestate statically attached but no
>   `attach` / `detach` overloads, so it is functionally dormant.
>   `attach` / `detach` are declared with `BQueueProducer[T,
>   ccMulti, ccCons, N, P, C]` (or analogue) in the param
>   signature; the compiler statically excludes ccSingle from the
>   overload set and produces a clean "type mismatch" diagnostic
>   that references the user-visible alias name. No `*Multi` /
>   `*Single` backing types exist (M5 R9 grep gate trivially
>   satisfied — there is no backing-type name to leak).
>
> - **Wall 3 acceptance — documented limitation.** typestates v0.9.3
>   does NOT statically catch use-after-destroy. The CFG analyzer
>   enforces "reaches terminal by end of scope," not "no method
>   calls on a value already in terminal state." Concretely:
>   `=destroy(q); q.push(item)` does NOT fail compile (the typestate
>   is in `QueueDestroyed`, but the push proc has no transition
>   pragma and the verifier sees no rule violation). Similarly, an
>   explicit `=destroy(q); =destroy(q)` double-destroy is not caught
>   by the destructor's `destructorTransition` because the second
>   call still treats the value as a fresh entry into the destructor
>   surface.
>
>   **Recovery path**: typestates v0.10+ post-terminal CFG mode (open
>   feature request) OR design pivot to consume-on-transition
>   destructors. For must-not-double-use sites where the failure
>   mode warrants runtime instrumentation, mirror
>   `pinned_scope.nim:128-131`'s `doAssert(not consumed, ...)`
>   pattern. v5.0.0 does NOT blanket-instrument BQueue or Queue
>   destructors so hot-path push/pop stays allocation-free and
>   branch-free.
>
> The user-visible API is unchanged from the original brief: smart
> constructors return `BQueue[...]` / `Queue[...]` aliases;
> `getProducer()` / `getConsumer()` return `BQueueProducer[...]` /
> view aliases; cardinality-illegal direct calls are still gated by
>'s `{.error.}` overloads (which take precedence over the
> typestate's destructor-only transition because the `{.error.}`
> overload is more-specific).

The reframe consolidates 7+ typestate queue families (`Sipsic`, `Sipmuc`,
`Mupsic`, `Mupmuc`, `UnboundedSipmuc`, `UnboundedMupsic`, `UnboundedMupmuc`,
plus their phantom variants) into two 6-param generics per the 3.3.11-B
reshape above: a bounded `BQueue[T, ccProd, ccCons, N, P, C]` and an
unbounded `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`. The standalone
`UnboundedSipsic[S, T]` SPSC type was ABSORBED into `Queue`'s
`(ccSingle, ccSingle)` arm (debra-free committed-flag-free protocol) and
its module deleted — it is no longer a separate type. The final shape
summarized in the addendum above is canonical.

Reclamation is cardinality-driven, not a phantom parameter. The
`(ccSingle, ccSingle)` arm uses the debra-free committed-flag-free
protocol; the multi-cardinality arms (mupsic-/sipmuc-/mupmuc-equiv) ship
LIVE epoch-based reclamation via nim-debra 0.8.0 (the `nim-debra >= 0.8.0`
precondition is met, so EBR ships in 5.0.0 — there is no deferred RC).
`ReclamationKind` (`rkNone` / `rkEbr`) survives only as a vestigial
re-export for bench-adapter / migration-shim compatibility; it is NOT a
type parameter on either generic.

### Refactor highlights (3.3.11-B)

The v5.0.0 reshape is measured against the pre-wave devel baseline
(merge-base `b6da7f60`):

- **Production-code surface**: 8 per-family modules deleted
  (`mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`, `sipsic.nim`,
  `unbounded_mupmuc.nim`, `unbounded_mupsic.nim`,
  `unbounded_sipmuc.nim`, `unbounded_sipsic.nim` — 2570 LOC total);
  replaced by `bqueue.nim` (1269 LOC, greenfield 6-param BQueue),
  `queue.nim` (1389 LOC, unified 6-param Queue absorbing the standalone
  `UnboundedSipsic`), `internal/shared.nim` (37 LOC), and
  `internal/typestates_dsl.nim` (21 LOC, attachment-pragma resolution
  shim). Plus typestate-machinery edits across
  `typestates/unbounded_*_push.nim` and `typestates/unbounded_*_pop.nim`.
- **Net src/ LOC delta**: +393 LOC (5903 → 6296). The growth is
  paid by typestate machinery (Middle-axis Lifecycle + Claim-state
  attachment) which is feature-bearing, not bloat; the per-family
  module deletions are offset by the typestate-attached BQueue/Queue
  surface plus view types.
- **Smart-constructor surface**: collapsed from 11 family-prefixed
  entry points (one per family + per-reclamation kind) to 2 primary
  generic constructors (`newBQueue`, `newQueue`) plus 8 family-named
  thin wrappers retained for grep continuity.
- **UnboundedSipsic absorbed into Queue** via
  `when (ccProd, ccCons) is (ccSingle, ccSingle):` branch with the
  legacy committed-flag protocol verbatim (debra-free, no manager).
- **Middle-axis typestates landed** (3.3.11-B.4.1.6):
  `BQueueLifecycle: BQueueInit -> BQueueDestroyed` on `BQueue`,
  `QueueLifecycle: QueueInit -> QueueDestroyed` on `Queue`, and
  `BQueueClaimState` / `QueueClaimState` (`Unclaimed -> ProducerClaimed
  | ConsumerClaimed | BothClaimed`) on the 4 view types
  (`BQueueProducer`, `BQueueConsumer`, `QueueProducer`,
  `QueueConsumer`). Wall 3 limitation: typestates v0.9.3 does not
  catch use-after-destroy in the CFG analyzer; see the "Bundle F
  revised design" subsection above for the documented recovery path.
- **Bench-binary size delta** (vs immediate pre-Bundle-F baseline
  `e0f2850`, release builds): total +15,088 bytes across 9 binaries
  (+0.74%). The largest grow-by binary is `bench_mpmc_mupmuc`
  (+25,616 bytes / +8.35%), reflecting the typestate-attachment
  codegen on the highest-cardinality topology. 7 of 9 binaries
  shrank or grew under 1%.
- **Test posture at v5.0.0 cut**: 5 MM lanes (orc / arc / refc /
  atomicArc+TSan / orc+ASan) green at 240/240 each, plus C++ lane
  240/240. `should_fail/runner.nim`: 14/14. R7 / R8 / R9 grep gates:
  clean.

### Removed (3.3.11-B late)

- **Stress test suite (`nimble stresstests`)**: the 9 legacy
  `stress-tests/t_*_threaded.nim` files referenced the deleted
  per-family aliases (`Mupmuc[N, P, C, T]`, `Sipmuc[N, C, T]`, etc.)
  and pre-DEBRA constructors. Rewiring 1,197 LOC across 9 files to
  the new BQueue/Queue surface with the attach/detach Claim-state
  idiom was estimated at multi-hour refactor scope (well beyond the
  v5.0.0 wrap-up budget). Per Bundle I principle ("do NOT silently
  disable failing tests — fix production code OR delete the test"),
  the stress test suite + `stresstests` nimble task are removed in
  v5.0.0. The MM lane matrix (5 lanes × 240 tests at maximum stress
  shape, plus TSan/ASan sanitizers) provides the primary
  concurrency-correctness signal; the dropped stress suite was
  duplicative single-shape coverage. Post-v5.0.0 work may resurrect a
  smaller targeted stress suite under the new surface if a gap
  surfaces.

### BREAKING

- Two unified queue generics. The seven non-SPSC queue families
  (`Sipsic`, `Sipmuc`, `Mupsic`, `Mupmuc`, `UnboundedSipmuc`,
  `UnboundedMupsic`, `UnboundedMupmuc`) plus the standalone
  `UnboundedSipsic` collapse into a bounded
  `BQueue[T, ccProd, ccCons, N, P, C]` (6 params, debra-free) and an
  unbounded `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` (6 params).
  `PinScopeCardinality` (`ccSingle` / `ccMulti`) is a static phantom on
  both. There is NO `RK` / `ReclamationKind` type parameter: reclamation
  is selected by cardinality (the `(ccSingle, ccSingle)` arm is
  debra-free; the multi arms are debra-integrated). `DeallocationStrategy`
  (formerly a runtime enum field on the unbounded queues) is now a static
  phantom `ST` (`stManual` / `stEager`) on `Queue`; the legacy enum
  values `Manual` / `Eager` remain exported as `const` aliases for grep
  continuity. `UnboundedSipsic[S, T]` was ABSORBED into `Queue`'s
  `(ccSingle, ccSingle)` arm and its module deleted. **No type aliases
  are provided** — every typed call site (`var q: Mupsic[...]`,
  `var u: UnboundedMupmuc[...]`, etc.) must migrate mechanically to the
  `BQueue[...]` / `Queue[...]` form (family-named smart constructors such
  as `newMupsicQueue` / `newUnboundedMupmucQueue` remain as ergonomic
  aliases). See `docs/migration.md` for the full migration table.
- `Queue` is non-copyable (move-only). Its `=copy` hook is a compile-time
  `{.error.}`: a `Queue` owns a heap `ptr Segment` chain and (for the
  debra-integrated, non-sipsic cardinalities) a `ptr DebraManager`, both
  reclaimed exactly once in `=destroy`. A field-wise copy would alias those
  owned pointers and double-free / use-after-free when both copies run their
  destructor. Move the `Queue` (the implicit `=sink` synthesized alongside
  `=destroy` is available) or share it across threads by `var` / `ptr`
  parameter; only copies are rejected. `BQueue` remains copyable — it owns
  only inline slot storage (no heap segments, no manager), so a field-wise
  copy is sound.
- Epoch-based reclamation ships LIVE in v5.0.0. The multi-cardinality
  unbounded arms (mupsic-/sipmuc-/mupmuc-equiv) integrate nim-debra 0.8.0
  (`>= 0.8.0`) directly; the `(ccSingle, ccSingle)` arm stays debra-free.
  The legacy unbounded `withPin:` ergonomics carry into the debra-
  integrated arms via the `Queue` facade. There is no deferred RC: the
  nim-debra precondition is met and EBR ships in the base release.
- Compile-time param-coherence guards split across the two generics:
  bounded guards live in `assertBQueueParams` (`bqueue.nim`,
  `validateBQueueParams[BQueue[T, ...]]()`); unbounded guards live in
  `assertQueueParams` (`queue.nim`, `validateQueueParams[Queue[T, ...]]()`,
  asserting `S > 0` and `MaxThreads > 0`). Calling a malformed
  parametrisation (e.g. `ccProd = ccMulti` with `P = 1`, `S` not
  positive, etc.) fails at compile time with the verbatim guard error
  messages.
- `CASAttempt` typestate restructured into a proper typestate union. `CASPending` now transitions to `CASSucceeded | CASFailed` (aliased as `CASResult`) via `executeCAS`, replacing the previous single-state design with `assumeSuccess` / `assumeFailure` escape hatches. The `assumeSuccess` and `assumeFailure` procs have been removed. Callers that drove `CASAttempt` outside the bundled MPMC machinery must migrate to the union return form. These helpers were only consumed by `tests/t_cas.nim`; the bundled MPMC machinery calls `compareExchangeWeak` directly and was unaffected. No public lock-free queue API is affected.

### Registration & lifecycle (unbounded multi-cardinality arms)

Debra thread registration moved to **attach time**. The auto-create
`newQueue` / family-named constructors (and `getProducer` /
`getConsumer`) no longer call `registerThread`; `registerThread` is
thread-affine (it stamps the calling thread and installs a per-thread
signal handler), so registering at construction would mis-route the
handle when the queue is later operated on a different thread. Each
operating thread now registers itself on its own thread before its first
push/pop. This is a BREAKING change to the call sequence for the
unbounded multi-cardinality arms.

**Debug builds now assert thread affinity.** `attach()` /
`attachConsumer()` stamp the registering thread's id (`attachedTid`, a
`when defined(debug):` field — zero layout/hot-path cost in release), and
the subsequent `push` / `pop` carries a `when defined(debug):` assert
that the operating thread matches the thread that attached. Operating a
view on a different thread than you attached on therefore fails fast in
debug builds; release builds carry NO such check (the mis-routed handle
would silently corrupt reclamation), so the affinity contract MUST be
honoured regardless of build mode.

- **Multi-producer / multi-consumer views must `attach()` before
  push/pop.** `QueueProducer.attach()` (for `ccProd == ccMulti`) and
  `QueueConsumer.attach()` (for `ccCons == ccMulti`) register the calling
  thread and store its `ThreadHandle` on the view. Both are
  `{.raises: [DebraRegistrationError].}`; the call is guarded
  (`if not self.claimed: self.handle = registerThread(...)`) so a repeat
  attach on the same view does not consume a second registry slot.
  `detach()` releases the view's claim (`self.claimed = false`) and does
  not raise. The `ccSingle` sides carry no `attach` / `detach` overload
  (the compiler statically excludes them with a user-visible-alias type
  mismatch).

- **The unbounded mupsic-equiv single consumer must call
  `attachConsumer()` before its first `pop`.** The single consumer pops
  directly through `Queue.pop` (no view), so it registers via
  `Queue.attachConsumer()` (`{.raises: [DebraRegistrationError].}`) on
  the thread that will pop. Auto-create no longer registers the consumer
  handle at construction. `pop` carries an `assert self.consumerAttached`
  guard that fails fast in debug builds if `attachConsumer` was skipped.
  `attachConsumer` is idempotent (guarded so a repeat call does not burn
  a second slot).

- **`MaxThreads` counts LIFETIME distinct operating threads, not the
  live count.** nim-debra 0.8.0 has no per-thread unregister, so each
  `attach()` / `attachConsumer()` consumes a registry slot for the
  manager's entire lifetime; `detach()` releases the view's claim but
  does NOT free the underlying slot. When the registry is exhausted,
  `registerThread` raises `DebraRegistrationError` (surfaced, never
  swallowed). Size `MaxThreads` for the total number of distinct threads
  that will ever operate the queue, not the maximum concurrent count.
  Repeated `detach()` / re-`attach()` on the same thread burns a fresh
  slot each time (there is no slot to reclaim), so churning attach/detach
  cycles will exhaust the registry even with a small live thread count.

- **`DebraRegistrationError` is a NEW propagatable exception.**
  `attach()` / `attachConsumer()` are `{.raises: [DebraRegistrationError].}`
  and fire this exception on `MaxThreads` slot exhaustion. Because
  registration moved out of the constructors and into these procs, the
  error now surfaces at the call site instead of at queue construction.
  Callers that previously declared `{.raises: [].}` around the code paths
  that operate the unbounded multi-cardinality arms MUST widen their
  raises set (or handle / convert the exception) to cover
  `DebraRegistrationError`.

- **Pre-v5 -> v5 migration.** Pre-v5.0.0, `get*()` (and the auto-create
  constructors) registered the debra handle immediately on the
  constructing / calling thread, so a view could be operated without any
  further setup. v5.0.0 returns an UNREGISTERED view: the caller MUST
  call `.attach()` on the operating thread before its first push/pop, and
  the mupsic-equiv single consumer MUST call `attachConsumer()` on the
  consumer thread before its first `pop` (auto-create no longer registers
  the consumer handle at construction). Minimal corrected idiom:

  ```nim
  # Pre-v5.0.0 (registered at get-time — REMOVED):
  #   var p = q.getProducer()      # already registered
  #   p.push(5)
  # v5.0.0 (register on the operating thread):
  var p = q.getProducer()
  p.attach()                       # on the producer thread, before push
  p.push(5)
  ```

- **Borrow constructors remain the epoch-sharing escape hatch.** The
  caller-provided-handle / caller-provided-manager `newQueue` overloads
  (e.g. `newUnboundedMupsicQueue[T, ST, S, MaxThreads](addr mgr,
  consumerHandle)`, `newUnboundedMupmucQueue[...](addr mgr)`) stay
  available for multi-queue setups that share one `DebraManager`.
  Callers using the handle-carrying mupsic borrow overload register the
  consumer handle themselves and MUST NOT also call `attachConsumer`.

  Auto-create idiom (mupmuc-equiv):

  ```nim
  var q = newUnboundedMupmucQueue[int, stEager, 8, 4]()
  var p = q.getProducer()
  p.attach()
  var c = q.getConsumer()
  c.attach()
  p.push(5)
  discard c.pop()
  ```

  Auto-create idiom (mupsic-equiv — single consumer pops via the queue):

  ```nim
  var q = newUnboundedMupsicQueue[int, stEager, 8, 4]()
  q.attachConsumer()               # on the consuming thread, before pop
  var p = q.getProducer()
  p.attach()
  p.push(1)
  discard q.pop()
  ```

### Added

- Multi-panel benchmark chart layout on `docs/benchmarks.md`: a hero
  panel highlighting lockfreequeues vs alternatives at the most-relevant
  shape, per-topology throughput panels, and a dedicated latency panel.
  Hero panel selects shape by preference order MPMC 4p4c → MPMC 2p2c →
  MPSC 4p1c → SPSC 1p1c, with a bounded-only fallback when no shape in
  the snapshot covers all comparison libraries.
- Latency panel rendering (`#bench-latency`) — log-y stepped ladder
  across the p50 / p95 / p99 / p999 / max percentiles emitted by
  `bench_latency.nim`.
- Library color discipline (`LIBRARY_COLORS` map in
  `docs/assets/bench-charts.js`): a single brand color shared across the
  full lockfreequeues family (sipsic / sipmuc / mupsic / mupmuc and
  their unbounded counterparts) and distinct stable colors for each
  comparison library, so toggling series in the legend never reassigns
  hues.
- Blocking-library visual differentiation: `threading_channels` and
  `nim_channel` / `nim_channels` are drawn with dotted lines plus a
  dedicated legend badge, marking them apart from the non-blocking
  comparison set.
- Five new guide pages under `docs/guide/`: Getting Started, Core
  Concepts, Bounded vs Unbounded, Memory Management, and Performance
  Tuning. Skeletons scaffolded against the typestates-pattern guide
  shape, then filled in via a dedicated prose pass.
- New top-level `docs/contributing.md` (substantially richer than the
  9-line root `CONTRIBUTING.md`), covering branch / version / CHANGELOG
  protocol and contributor workflow.
- "How to read these numbers" and "When to pick lockfreequeues"
  narrative sections in `docs/benchmarks.md`, surfacing methodology
  context above the chart so readers don't have to dig through the
  benchmarks README to interpret the numbers.
- Hybrid README BENCHMARKS block: headline number (10.6× faster than
  system Channel at MPMC 4p4c) plus the existing four-row variant table
  plus a link line to the live chart page. Replaces the prior
  table-only block.
- Representative `docs/assets/bench-results/example.json` BMF fixture
  used by the chart for fallback rendering when `latest.json` is
  unavailable (e.g. fresh PRs before the snapshot pipeline runs on
  devel).
- Four new contract tests pinning the chart's BMF surface area: DOM
  container IDs (`#bench-chart`, `#bench-latency`, …), `LIBRARY_COLORS`
  coverage of every library slug emitted by the bench binaries,
  `BLOCKING_LIBRARIES` membership for blocking-API libraries, and
  `example.json` schema validity.
- Defensive fallback step in `bench.yml` writing a
  `_status: "fallback"` marker into `latest.json` when `merge_bmf.py`
  fails or is cancelled, so the chart's silent-on-error behaviour
  cannot mask a broken upload pipeline.
- Latency p99 + throughput regression gating in Bencher (PR 6, Track 6).
  `bench.yml`'s base-branch tracking step now configures per-measure
  thresholds in a single `bencher run` invocation: `latency_p99_ns`
  with `--threshold-upper-boundary 0.99` (regression = latency
  increase) and `throughput_ops_ms` with `--threshold-lower-boundary
  0.99` (regression = throughput drop). Both use `--threshold-test
  t_test --threshold-max-sample-size 64`, terminated by
  `--thresholds-reset` so only the explicitly-listed thresholds
  remain active. Threshold activation requires ≥ 10 prior runs
  accumulated in Bencher to calibrate the t-test baseline (Task 6.4
  stability soak gate). Also corrects a prior measure-name mismatch:
  the earlier `--threshold-measure throughput` never matched any
  emitted measure (the actual key is `throughput_ops_ms`), so the
  previous throughput threshold was a no-op.
- `latency_p999_ns` and `latency_max_ns` measures emitted by
  `bench_latency.nim` (PR 6, Track 6). Each bounded variant slug
  (`lockfreequeues_{sipsic,sipmuc,mupsic,mupmuc}/<topology>/1p1c`)
  now carries the full p50 / p95 / p99 / p999 / max latency tuple in
  the merged BMF, available for the Bencher dashboard and downstream
  comparison charts. `t_bench_latency.nim` extended to assert all
  four extra measures appear on every bounded variant in the smoke
  shape.
- `HistogramTopK` raised from 1000 to 5000 (PR 6, Task 6.2).
  `runLatencyHarness` builds a fresh Histogram per run and averages
  per-run percentiles (design 2.5) — each histogram only sees
  `BenchLatencyMessageCount` samples, NOT `messageCount × runCount`.
  At the default 100K samples per run, K=1000 was already adequate
  (TopK + Reservoir already captured every sample exactly). The bump
  to K=5000 is anticipatory: an operator who overrides
  `BenchLatencyMessageCount` upward (e.g. ~5M for a tail-stress
  configuration) needs ~5000 in the exact top-K stratum to keep p999
  (tail rank = MessageCount × 0.001) outside the rescaled-reservoir
  stratum. Memory cost: 5000 × 8B = 40KB additional per histogram,
  negligible vs the 99K-sample reservoir. New `t_bench_common.nim`
  test stress-checks the design choice by asserting p999 within 5%
  of sort fallback on a single 3.3M log-normal stream.
- Interactive uPlot throughput chart on the docs site (PR 5, Track 5).
  `docs/benchmarks.md` embeds a `<div id="bench-chart">` container plus
  a vendored `uPlot 1.6.27` IIFE bundle and a vanilla-JS wiring module
  (`docs/assets/bench-charts.js` + `docs/assets/bench-charts.css`).
  The chart fetches the merged BMF snapshot from the relative URL
  `./assets/bench-results/latest.json` so the same page works under
  the `/dev/`, `/latest/`, and `/v*/` mike aliases without rewrite.
  Library-toggle legend hides/shows series; log-scale Y axis toggle
  switches between linear and log; hover tooltips show mean ± stddev
  when `lower_value` / `upper_value` are present in the underlying
  measure (throughput). Soft-skipped (library, shape) cells render as
  gaps, not zeros. Graceful fallbacks render an inline message on
  fetch errors, missing uPlot global, or empty BMF.
- BMF snapshot publishing pipeline (PR 5, Track 5). New step in
  `bench.yml`'s `bench-upload` job runs only on `push` to
  `refs/heads/devel`, copies `merged.json` to
  `docs/assets/bench-results/<sha>.json` AND
  `docs/assets/bench-results/latest.json`, and pushes the snapshot
  back to `devel` as `github-actions[bot]` with a `[skip ci]` commit
  message. Three-layer loop-prevention per design §5.X:
  (1) `[skip ci]` marker (primary), (2) `paths-ignore` extension to
  `docs/assets/bench-results/**` on both `pull_request` and `push`
  triggers (secondary), and (3) bot-actor guard on the `bench` and
  `bench-upload` jobs (tertiary).
- Devel-triggered docs deploy (PR 5, Track 5). `docs.yml` now triggers
  on push to `devel` in addition to `main` / `master`, and the
  "Deploy docs (dev)" step's `if:` clause includes `devel`. A new
  post-deploy "Verify mike asset path" step (design §5.Y) curls
  the published BMF snapshot URL, asserts HTTP 200, and asserts the
  body parses as JSON; the chart's silent-on-404 behaviour would
  otherwise hide a broken asset path.
- `THIRD_PARTY_LICENSES.md` records the uPlot vendoring (1.6.27, MIT,
  vendored at `docs/assets/uplot-1.6.27.iife.min.js`) with a precise
  upgrade procedure including the jsdelivr URL and SHA-256
  verification path. `.gitattributes` gains
  `docs/assets/uplot-*.js linguist-vendored=true linguist-generated=true`
  and `docs/assets/bench-results/*.json linguist-generated=true`.
- New `benchmarks/tests/test_bench_charts_contract.py` (9 tests)
  guards the BMF -> chart contract: slug grammar
  `<library>/<topology>/<P>p<C>c`, measure regex
  `^[a-z][a-z0-9_]*$`, finite numeric values, throughput-measure
  presence, and the existence of the three checked-in chart assets.
  Mirrors the JS `parseSlug` logic in Python so drift is caught at
  CI time rather than in production.
- `docs/benchmarks.md` registered in `mkdocs.yml`'s nav (previously
  unreachable from the docs landing page) and the four-row §4.1
  fairness caveats embedded verbatim immediately below the chart so
  readers see the methodology footnotes within one viewport
  regardless of which library combination they toggle.
- `benchmarks/README.md` "Updating the README summary" subsection
  codifies the new hand-curation procedure for the README BENCHMARKS
  markers (which shapes to read, where to read them, when to commit).
- Bench `meta.adapters.*` meta-block emission protocol unified under
  `benchmarks/nim/adapter_versions.nim`: every adapter records a
  `version` (or `null` when the upstream exposes no version macro), a
  `kind` discriminator (`nimble-resolved`, `cargo-locked`,
  `vendored-content-hash`, `vendored-version-macro`, `system-package`,
  `compiler-builtin`), and — for vendored libraries without a version
  macro — a SHA-1 `fingerprint` of the header bytes computed at
  compile time plus a `pinned_sha_per_readme` cross-check field.
  `status` is OMITTED on the success path; absent / build-without-*
  / unknown cases carry the corresponding explicit status string.
- Five new vendored / nimble / system adapters land in v5.0.0
  alongside the meta-block reshape: three Rust crates riding the
  existing `bench-ffi-crossbeam` cdylib (`crossbeam_queue::SegQueue`,
  `flume::Sender/Receiver`, `kanal::Sender/Receiver`) and five
  C/C++ vendored targets (`atomic_queue` SPSC + MPMC,
  `liblfds7.1.1` bss + bmm, `rigtorp::mpmc::Queue`,
  `rigtorp::SPSCQueue`, MoodyCamel `concurrentqueue`). Each entry is
  third-party-license-tracked in `THIRD_PARTY_LICENSES.md` and gated
  behind `-d:adapter_<slug>_available` so production builds are
  unaffected.

### Changed

- `benchmarks/nim/bench_mpmc.nim` split into per-family binaries
  (`bench_mpmc_mupmuc.nim` + `bench_mpmc_sipmuc.nim`) as the v5.0.0 B3
  bench-binary-layout mitigation. Co-compiling the Mupmuc grid, the
  Sipmuc shapes, the Queue-bounded parity paths, the Nim channels
  grid, and the MVP comparison adapters into a single release binary
  was producing a -39.6% ± 1.2% throughput artifact on
  `sipmuc/mpmc/1p1c` even though Queue's SPMC pop generated C is
  byte-for-byte identical to the legacy Sipmuc pop. Isolating each
  family into its own binary removes the cross-family iCache
  contention surface at the source. CI matrix (`bench.yml`), local
  runner (`benchmarks/runner.py`), the `nimble benchmarks` task,
  the topology-split deletion-safety tests, and the nightly
  `bench-comparison.yml` crossbeam workflow all enumerate both new
  binaries in place of the pre-split single. MVP comparison adapters
  (boost.lockfree, crossbeam ArrayQueue, threading.Chan) live in the
  mupmuc binary because their slug shape matches the mupmuc grid.
- The three pre-existing guide-shaped pages (`safety-model.md`,
  `slot-ownership-typestates.md`, `examples.md`) moved from
  `docs/` to `docs/guide/` so the entire guide track lives under one
  directory. Internal links updated; mkdocs nav follows the move.
- API reference pages for `sipsic`, `mupsic`, and `mupmuc` expanded to
  match the structural template established by `sipmuc.md` (consistent
  section ordering, signatures, examples, cross-links).
- mkdocs `nav:` restructured to a top-level `Guide` grouping (typestates
  pattern), with the API reference and benchmarks sitting alongside it
  rather than scattered through the tree.
- `mkdocs.yml` aligned with the typestates pattern: `include-markdown`
  plugin enabled, `theme.custom_dir: docs/overrides` wired in,
  `show_attribution: false` set on the `mkdocstrings-nim` handler,
  and `click<8.3.0` pinned via the docs requirements to dodge an
  upstream incompatibility.
- `docs.yml` workflow swapped its in-place `nim.cfg` patching for
  `nimble install nim -y` to expose the Nim compiler API to
  `mkdocstrings-nim` more cleanly. Nim pinned to 2.2.8 to match the
  build matrix, and a daily cron at 05:17 UTC was added so the live
  chart picks up new BMF snapshots even when no commit lands on devel.
- `bench.yml` snapshot-commit message now carries `[skip ci]` (third
  loop-prevention layer alongside the existing `paths-ignore` filter
  and the bot-actor guard on the bench / bench-upload jobs).
- `bench.yml` `Track base branch benchmarks with Bencher` step marked
  `continue-on-error: true` as a release-day band-aid for an upstream
  Bencher CLI threshold-model validation quirk; threshold gating remains
  dormant pending the Track 6 calibration soak.
- `README.md` BENCHMARKS markers now hold a hand-curated four-row
  summary table (Sipsic / Sipmuc / Mupsic / Mupmuc bounded at one
  representative shape each) plus a link line to the live chart page
  at `https://elijahr.github.io/lockfreequeues/latest/benchmarks/`,
  per design §4.4. Initial cells contain placeholders; the release PR
  fills them in. The chart page absorbs run-to-run noise; the README
  intentionally captures only the most recent release's headline
  numbers.

### Removed

- `benchmarks/render_readme.nim` and its test
  `tests/t_render_readme.nim`. The auto-rendered README path is
  replaced by hand curation (above). Pre-deletion release-tag check
  (per impl plan 5.8): `v3.2.0` and `v4.0.0` each ship the renderer
  in their tagged tree; deleting on devel does not mutate those
  tags. No CI workflow, nimble task, or test runner referenced the
  renderer.

- Legacy `nim doc`-generated HTML output (`json/` directory, 17
  files) and the `nimdoc.cfg` config that drove it. The mkdocs +
  mike pipeline introduced in v4.0.x is now the canonical docs
  build path; legacy artifacts were not regenerated by current CI.

- Comparison expansion (PR 4, Track 4): three new third-party adapters
  reach the comparison set. `moodycamel_adapter.nim` wraps
  `moodycamel::ConcurrentQueue` (BSD-2-Clause / Boost dual,
  `mpmc_unbounded`) via a thin `extern "C"` shim isolating Nim from
  upstream's template machinery. `threading_channels_adapter.nim`
  wraps the nimble `threading` package's `Chan[T]` (MIT, `mpmc`
  bounded) using non-blocking `trySend` / `tryRecv`.
  `nim_channel_adapter.nim` wraps Nim's stdlib `system.Channel[T]`
  (MIT, `mpsc` bounded) with blocking-on-full producer semantics
  (apples-to-oranges fairness caveat documented inline + asterisked
  in the bench README). All three are gated behind
  `-d:adapter_<library_slug>_available` defines; absent gates produce
  no symbol references and the production builds are unchanged.
- Vendored MoodyCamel `concurrentqueue` at upstream commit
  `d655418bb644b7f85159d94c591d7d983949fb81` under
  `benchmarks/vendor/concurrentqueue/`: `concurrentqueue.h` + upstream
  `LICENSE.md` + a project-authored `README.md` documenting the
  pinned SHA and upgrade procedure. The
  `moodycamel_wrapper.cpp` shim exposes `mc_init` / `mc_push` /
  `mc_pop` / `mc_destroy` for `uint64_t`. New
  `benchmarks/nim/smoke/smoke_moodycamel.nim` and
  `benchmarks/nim/smoke/smoke_threading_channels.nim` run a 32-item
  push/pop round-trip as fast pre-flight checks in CI.
- `bench.yml` gains the `force_skip_moodycamel` /
  `force_skip_threading_channels` / `force_skip_nim_channel`
  `workflow_dispatch` boolean inputs and per-library install → smoke →
  set-flag pipelines (design §2.6 soft-skip pattern). MoodyCamel's
  install step is a `test -f` against the vendored header so the
  bench is reproducible without network egress; threading uses
  `nimble install threading`; system.Channel needs no install.
  Failure at install or smoke flips the binary's compile flags so the
  slugs are omitted from the BMF instead of failing the workflow; the
  `Annotate skipped` step emits a `::warning title=Adapter
  skipped::...` annotation visible on the PR check summary. The
  `bench_mpsc` compile step now consumes `ADAPTER_FLAGS` so the new
  `nim_channel` adapter wires in; the `bench_unbounded` compile step
  honours `NIM_MODE=cpp` when MoodyCamel is enabled.
- `tests/t_bench_adapters.nim` extends with three new
  `when defined(adapter_<lib>_available):` blocks covering 1000-item
  push/pop round-trip set equality for the new adapters (gated under
  `nim cpp` for MoodyCamel).
- `THIRD_PARTY_LICENSES.md` lands its first vendored entry
  (`concurrentqueue (MoodyCamel)`, BSD-2-Clause / Boost dual, pinned
  to commit `d655418bb644b7f85159d94c591d7d983949fb81`) plus
  unvendored entries for the nimble `threading` package (MIT) and
  Nim `system.Channel` stdlib (MIT). Placeholder PR-4 reservation
  removed.
- New `.gitattributes` rule
  `benchmarks/vendor/** linguist-vendored=true linguist-generated=true`
  excludes the vendored MoodyCamel header from GitHub language stats
  and code-search noise.
- `benchmarks/README.md` comparison table extends to seven upstream
  libraries / nine adapter variants with install commands for each.
- Bench-binary slug coverage extends per design §2.4: `bench_mpmc`
  emits `threading_channels/mpmc/{1,2,4}p{1,2,4}c` (9 shapes);
  `bench_mpsc` emits `nim_channel/mpsc/{1,2,4}p1c` (3 shapes);
  `bench_unbounded` emits
  `moodycamel/ConcurrentQueue/mpmc_unbounded/{1,2,4}p{1,2,4}c` (9
  shapes). Each carries a `throughput_ops_ms` measure with
  `value=mean`, `lower_value=mean-stddev`, `upper_value=mean+stddev`.
- New `benchmarks/nim/bench_common.nim` shared harness module exporting:
  `Topology` enum, `BMFEmitter` (alpha-sorted Bencher Metric Format JSON
  emission), `Histogram` (min-heap top-K + Algorithm R reservoir for
  stratified-percentile estimation, p99 within 1% of sort fallback on
  100k log-normal samples), generic `runThroughputHarness` and
  `runLatencyHarness` (1P/1C ping-pong RTT with monotonic-ns timing and
  per-run percentile aggregation), and Stats helpers (mean / stddev /
  minVal / maxVal / linear-interpolation percentile).
- Five new lockfreequeues adapters in `benchmarks/nim/adapters/`:
  `lockfreequeues_sipmuc_adapter.nim`, `lockfreequeues_mupsic_adapter.nim`,
  `lockfreequeues_unbounded_sipsic_adapter.nim`,
  `lockfreequeues_unbounded_sipmuc_adapter.nim`,
  `lockfreequeues_unbounded_mupmuc_adapter.nim`. Each exposes
  `topologiesSupported: set[Topology]` and the standard `push`/`pop`
  shape consumed by the shared harness. The unbounded adapters store
  the queue inline (not via `ptr`) to dodge a Nim 2.2.6 codegen bug
  triggered by generic-pointer destructor calls when bench_common is
  imported.
- New `benchmarks/merge_bmf.py` CLI: stateless union of per-binary BMF
  JSON fragments into a single output file. Exits 1 on `(slug, measure)`
  collisions naming both colliding inputs in stderr. Output slugs and
  measures alpha-sorted. Pure-stdlib (no third-party deps); covered by
  `benchmarks/tests/test_merge_bmf.py` (10 tests).
- `bench_throughput` `--bmf-out=<path>` flag emits Bencher Metric Format
  JSON natively. The flag is purely additive: with the flag absent, the
  binary is bit-for-bit unchanged from the prior release (same stdout
  text, same positional CLI: `bench_throughput sipsic mupmuc
  unbounded_mupsic channels`). Emitted slugs:
  `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_mupmuc/mpmc/{1,2,4,8}p{1,2,4,8}c`,
  `lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c`,
  `nim_channels/mpmc/{1,2,4}p{1,2,4}c`. Each carries a
  `throughput_ops_ms` measure with `value=mean`, `lower_value=mean-stddev`,
  `upper_value=mean+stddev`.
- Per-variant compile-time run-count overrides:
  `-d:BenchSipsicRuns=N`, `-d:BenchSipsicWarmup=N`,
  `-d:BenchMupmucRuns=N`, `-d:BenchMupmucWarmup=N`,
  `-d:BenchChannelsRuns=N`, `-d:BenchChannelsWarmup=N`. Defaults match
  the prior hard-coded `runs = 10`, so production runs are unchanged.
- `bench_latency` now emits Bencher Metric Format JSON natively via
  `--bmf-out=<path>`, mirroring `bench_throughput`'s CLI surface (PR 1).
  Positional args filter the variants run (`sipsic`, `mupmuc`, `sipmuc`,
  `mupsic`); without any positional arg, all four bounded lockfreequeues
  variants run at the 1p1c smoke shape. Emitted slugs:
  `lockfreequeues_sipsic/spsc/1p1c`,
  `lockfreequeues_sipmuc/mpmc/1p1c`,
  `lockfreequeues_mupsic/mpsc/1p1c`,
  `lockfreequeues_mupmuc/mpmc/1p1c`. Each carries
  `latency_p50_ns` / `latency_p95_ns` / `latency_p99_ns` measures
  (`latency_p999_ns` / `latency_max_ns` deferred to PR 6's threshold-
  gating work). The binary is built on top of
  `bench_common.runLatencyHarness` and uses per-binary intdefines:
  `-d:BenchLatencyRuns=N` (default 33), `-d:BenchLatencyMessageCount=N`
  (default 100_000), `-d:BenchLatencyWarmupRuns=N` (default 3).
- New `bench-latency` job in `.github/workflows/bench.yml` sibling to
  `bench-throughput`. Both jobs upload per-binary BMF artifacts
  (`bench-throughput-bmf` / `bench-latency-bmf`) consumed by a new
  `bench-upload` job that downloads via `actions/download-artifact@v4`
  pattern `bench-*-bmf`, runs `merge_bmf.py` to union the fragments,
  and performs the single `bencher run` upload that co-locates latency
  + throughput measures on shared per-slug histories. (Multiple
  `bencher run` invocations create separate Bencher Reports and would
  NOT co-locate measures — see merge rationale in design 1.)
- Four new topology-split throughput binaries replacing the legacy
  `bench_throughput.nim` (PR 2):
  `benchmarks/nim/bench_spsc.nim` (Sipsic 1p1c),
  `benchmarks/nim/bench_mpsc.nim` (Mupsic {1,2,4}p1c),
  `benchmarks/nim/bench_mpmc.nim` (Mupmuc {1,2,4}p{1,2,4}c plus 8p8c
    oversubscription, Sipmuc 1p{1,2,4}c, Nim channels {1,2,4}p{1,2,4}c),
  `benchmarks/nim/bench_unbounded.nim` (all four lockfreequeues
    unbounded variants at their natural shapes).
  Each emits BMF JSON via `--bmf-out=<path>` with the same per-slug
  `throughput_ops_ms` shape as the prior binary. Each owns its own
  per-binary intdefines (`-d:BenchSpscRuns/MessageCount/Warmup`,
  `-d:BenchMpscRuns/...`, `-d:BenchMpmcRuns/...`, plus four pairs of
  `-d:Unbounded<Variant>Runs/MessageCount` per design 2.5) so CI can
  budget each topology independently.
- New `benchmarks/scripts/superset_check.py`: slug-set deletion-safety
  guard that exits 0 when the post-split BMF covers every slug in the
  pre-split fixture (`tests/fixtures/pre-split-slugs.json`) and
  exits 1 with the missing slugs alpha-listed on stderr otherwise.
  Run by `bench-upload` immediately after `merge_bmf.py` so any
  silent slug regression introduced by future edits to the topology
  binaries fails the PR check. Covered by 9 unit tests in
  `benchmarks/tests/test_superset_check.py`.
- `benchmarks/tests/test_merge_bmf.py` gains `test_five_input_union`
  covering the upload-job pipeline shape: 5 sibling fragments (one per
  topology binary) merged via `merge_bmf.py` produce a single output
  whose slug set is the disjoint union, with shared slugs carrying
  measures from every input binary.
- Five third-party comparison adapters land in `benchmarks/nim/adapters/`
  for the comparison MVP (PR 3, Track 3): `loony_adapter.nim`
  (LoonyQueue, MIT, mpmc_unbounded), `boost_lockfree_queue_adapter.nim`
  (`boost::lockfree::queue`, BSL-1.0, mpmc bounded),
  `boost_lockfree_spsc_adapter.nim`
  (`boost::lockfree::spsc_queue`, BSL-1.0, spsc bounded),
  `crossbeam_array_queue_adapter.nim` (`crossbeam_queue::ArrayQueue`,
  Apache-2.0 OR MIT, mpmc bounded), `crossbeam_seg_queue_adapter.nim`
  (`crossbeam_queue::SegQueue`, Apache-2.0 OR MIT, mpmc_unbounded).
  Each is gated behind a `-d:adapter_<library_slug>_available` define;
  absent gates produce no symbol references and the production builds
  are unchanged. Tests in `tests/t_bench_adapters.nim` cover a
  1000-item push/pop round-trip per adapter.
- New Rust crate `benchmarks/rust/bench-ffi-crossbeam/`: a `cdylib`
  exposing 8 `extern "C"` fns (`cb_array_init/push/pop/destroy`,
  `cb_seg_init/push/pop/destroy`) consumed by the Crossbeam Nim
  adapters. Pinned via `rust-toolchain.toml` to `stable`. Six
  integration tests cover round-trip set equality for both queue
  types, capacity edges, empty-pop, and null-pointer tolerance.
- New `benchmarks/nim/smoke/` directory with `smoke_boost.nim` and
  `smoke_crossbeam.nim`: 32-item push/pop round-trip binaries used as
  fast pre-flight checks in CI before the full bench compile.
- New workflow `.github/workflows/bench-comparison.yml`: dedicated
  Crossbeam comparison job triggered by nightly cron (`0 4 * * *`),
  `workflow_dispatch`, and targeted path pushes to `devel` (anything
  under `benchmarks/rust/**` or `benchmarks/nim/adapters/crossbeam_*`).
  Builds the cdylib via `dtolnay/rust-toolchain@stable` +
  `Swatinem/rust-cache@v2`, runs the cdylib integration tests,
  compiles `bench_mpmc` + `bench_unbounded` with the crossbeam gates,
  merges via `merge_bmf.py`, and uploads to a separate Bencher Report.
  Crossbeam is intentionally NOT in `bench.yml` so PR critical-path
  time stays unchanged.
- `bench.yml` gains the `force_skip_boost` / `force_skip_loony`
  `workflow_dispatch` boolean inputs and a per-library install ->
  smoke -> set-flag pipeline (design §2.6 soft-skip). Failure at
  install or smoke flips the binary's compile flags so the slugs are
  omitted from the BMF instead of failing the workflow; the
  `Annotate skipped` step emits a `::warning title=Adapter
  skipped::...` annotation visible on the PR check summary.
- New `THIRD_PARTY_LICENSES.md` records license obligations for the
  comparison MVP libraries (Loony MIT, Boost BSL-1.0, Crossbeam
  Apache-2.0 OR MIT) and reserves placeholder entries for
  concurrentqueue (PR 4) and uPlot (PR 5).
- New `src/lockfreequeues/internal/aligned_alloc.nim` exporting
  `allocAligned[T]: ptr T` via a local `posix_memalign` shim. Used by
  the four unbounded queue variants to allocate cache-line-aligned
  segments (64-byte alignment instead of `c_calloc`'s 16-byte ABI
  guarantee), eliminating the false-sharing asymmetry vs other
  libraries flagged in design §4.2.

### Fixed

- Cache-line padding for unbounded queue segments. Each `Segment` field
  participating in producer/consumer coordination now carries
  `{.align: CacheLineBytes.}`, and the four unbounded variants
  (`unbounded_sipsic`, `unbounded_sipmuc`, `unbounded_mupsic`,
  `unbounded_mupmuc`) allocate via `allocAligned[Segment[S, T]]()`
  instead of `c_calloc`. Verified by `tests/t_unbounded_padding.nim`
  (8 assertions across 4 variants, green under c/cpp/arc/refc).

### Changed

- `bench_throughput.nim` now natively emits Bencher Metric Format JSON
  via `--bmf-out=<path>`. The CI workflow (`.github/workflows/bench.yml`)
  was rewired to consume the native output and feed it through
  `merge_bmf.py` before uploading to Bencher.dev — the previous Python
  regex parser (`bmf_adapter.py`) is gone.
- The four existing lockfreequeues adapter files renamed to the
  canonical `<library_slug>_adapter.nim` convention with `git mv`
  (history preserved): `lockfreequeues_sipsic.nim`,
  `lockfreequeues_mupmuc.nim`, `lockfreequeues_unbounded_mupsic.nim`.
  Each gained a `topologiesSupported: set[Topology]` constant for the
  upcoming PR 3 binary-split.
- `benchmarks/render_readme.nim` rewritten to consume the new BMF JSON
  shape directly (`{slug: {measure: MeasureValue}}`) instead of the
  legacy `bench_main` aggregator output. The slug walk decomposes
  `<lib>/<topology>/<P>p<C>c` back into the (impl, thread_config) pair
  the table renders.
- `benchmarks/runner.py` and `lockfreequeues.nimble` `task benchmarks`
  redirected from `bench_main` to `bench_throughput --bmf-out=<path>`.
- `benchmarks/README.md` rewritten to document the new flow
  (bench_common module, adapter convention, `--bmf-out` flag,
  merge_bmf.py, expected slug set).
- `benchmarks/nim/adapter.nim` now re-exports `PushResult` / `PopResult`
  from `bench_common` instead of defining its own copies, unifying the
  two parallel type definitions introduced by PR 0 Task 0.1. Both
  adapter packs (legacy `lockfreequeues_sipsic` / `lockfreequeues_mupmuc`
  / `channels` and the newer `lockfreequeues_sipmuc` / `mupsic` /
  `unbounded_*`) now flow through the same `runLatencyHarness` and
  `runThroughputHarness` without per-call-site type conversion. No
  external API change: legacy callers that imported `./adapter` for
  `PushResult` / `PopResult` continue to compile (PR 1).
- `.github/workflows/bench.yml` now runs the five topology-split
  binaries (`bench_spsc`, `bench_mpsc`, `bench_mpmc`, `bench_unbounded`,
  `bench_latency`) as a GitHub Actions matrix instead of the legacy
  pair of bench-throughput / bench-latency jobs. Each matrix entry
  has its own `timeout-minutes: 12` budget so a hang in one binary
  cannot burn the entire workflow's clock; the surviving binaries
  finish, the bench-upload job merges what arrived, and the operator
  gets partial Bencher coverage rather than no coverage. The
  bench-upload job now also runs the `superset_check.py` deletion-
  safety guard between `merge_bmf.py` and `bencher run` (PR 2).
- `benchmarks/runner.py` and `lockfreequeues.nimble` `task benchmarks`
  iterate the five topology-split binaries and merge their fragments
  via `merge_bmf.py` (PR 2).
- `benchmarks/README.md` rewritten to describe the 5-binary pipeline
  (matrix CI job, per-binary intdefines, deletion-safety guard, the
  merged BMF schema where one slug can carry both throughput and
  latency measures) (PR 2).

### Removed

- `benchmarks/bmf_adapter.py` — Python regex parser that converted
  `bench_throughput` stdout text into BMF JSON. Replaced by native BMF
  emission via `--bmf-out=`.
- `benchmarks/test_bmf_adapter.py` — unit tests for the parser.
  Replaced by `benchmarks/tests/test_merge_bmf.py`.
- `benchmarks/nim/bench_main.nim` — aggregator binary that wrapped
  bench_throughput + bench_latency and produced a custom JSON shape.
  `bench_throughput` is now the canonical entry point.
- `benchmarks/nim/bench_throughput.nim` — single multi-topology
  throughput driver, replaced by the four topology-split binaries
  `bench_spsc`, `bench_mpsc`, `bench_mpmc`, and `bench_unbounded`.
  The pre-split slug fixture committed at
  `tests/fixtures/pre-split-slugs.json` plus the `superset_check.py`
  guard wired into bench.yml enforces that no slug from the legacy
  binary silently disappears across the split (PR 2).
### Changed (typestates 0.7 uplift)

- Bump minimum `typestates` to 0.7.2. Pulls in the upstream `match` macro fixes for generic and cross-module contexts shipped in nim-typestates v0.7.1 / v0.7.2.
- `opaqueStates = true` and `initial:` / `terminal:` DSL blocks added to 5 SET typestates: `CASAttempt`, `SPSCPopOp`, `SPSCPushOp`, `VirtualValueN`, and `VirtualValueN1`.
- 8 hand-written `case .kind` dispatches across 4 facade modules (`sipsic.nim`, `mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`) replaced with the generated `match` macro for compile-time exhaustiveness.

### Added (typestates 0.7 uplift)

- CI: `typestates verify -W --format=github src/` step in `build.yml` to gate the typestate model against drift.

### Fixed (typestates 0.7 uplift)

- 22 read-only typestate accessors across `src/lockfreequeues/typestates/` now carry `{.notATransition.}`. typestates' verifier flagged these once `typestates verify -W` was wired into CI; the procs are pure data extraction and were never transitions.

### Dependencies & verification (typestates 0.10.0 AST verifier)

- Bump minimum `typestates` to 0.10.0 and minimum `debra` to 0.8.0. The
  transitive dependency chain is now `typestates >= 0.10.0`,
  `debra >= 0.8.0`.
- Re-audited the typestate model under the 0.10.0 AST verifier. The
  pre-0.10.0 verifier used a line-by-line text scanner with a multi-line
  silent-unscan defect; the AST verifier walks the parsed tree instead.
  Re-auditing confirmed all 22 existing `{.notATransition.}` markings and
  added 38 that the old text scanner had silently missed (0 spurious, 0
  drift). The verifier now reports zero findings.

### Added (v5.0.0 unified Queue — Phase 1)

> **Historical Phase-1 snapshot (superseded by 3.3.11-B).** The bullets
> below describe the unified Queue *as built in Phase 1* — the 10-param
> `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]` shell with
> the `when RK == rkEbr` body under a `when false:` carve-out. Phase
> 3.3.11-B reshaped this into the two final 6-param generics (`BQueue`
> bounded, `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` unbounded),
> dropped the `RK` parameter (reclamation is now cardinality-driven), and
> absorbed `UnboundedSipsic` into `Queue`. See the 3.3.11-B reshape note
> at the top of this release for the shipped surface. The entries are
> retained for the audit trail.

- `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]` generic
  type shell at `src/lockfreequeues/queue.nim`. Field layout splits by
  cardinality: `ccSingle × ccSingle` uses `StorageN1[N, T]` (N+1 slots,
  `Atomic[int]` head/tail) lifted verbatim from `sipsic.nim`; all other
  bounded shapes use `MPMCCellArrayN[N, T]` (Vyukov per-slot seq
  counters, `Atomic[uint64]` head/tail) lifted verbatim from
  `mupsic.nim` / `sipmuc.nim` / `mupmuc.nim`. Param order is
  LOAD-BEARING per Doc C §3.0.1: `T, ccProd, ccCons, ST, RK, N, P, C,
  S, MaxThreads`. The `when RK == rkEbr` field declarations are wrapped
  in `when false:` for the Phase 1 mode-(a) carve-out so the type
  instantiates without a `nim-debra >= 0.8.0` dependency; Track E
  rewrites those declarations with real debra types when the
  nim-debra worktree linkage lands.
- `ReclamationKind` enum (`rkNone` / `rkEbr`) and `PinScopeCardinality`
  enum (`ccSingle` / `ccMulti`) under `src/lockfreequeues/reclamation.nim`
  and `src/lockfreequeues/strategy.nim`. Both are exposed as static
  phantom parameters on `Queue` and travel with their enum type
  (visible to any module that imports `queue`; per-member re-exports
  are rejected by Nim).
- `DeallocationStrategy` lifted to a static phantom parameter `ST`
  (`stManual` / `stEager`) on `Queue`. The runtime `strategy:` field on
  the legacy `Unbounded*` queues is removed; every `if self.strategy
  == X` collapses to `when ST == X` and the two strategies
  monomorphize separately. Legacy enum values `Manual` and `Eager`
  remain exported as `const` aliases for `stManual` / `stEager` to
  ease grep continuity.
- 9 compile-time `validateQueueParams` guards (Doc C §3.0.2.4) wired
  through a sibling generic template `assertQueueParams`. Nim does not
  accept `static:` blocks (nor `{.error.}` pragmas) directly inside an
  object type body, so the guards are lifted out of the type
  declaration and invoked by `validateQueueParams[Queue[T, ...]]()`.
  Condition expressions and error messages are byte-identical with
  Doc C §3.0.2.4; only the syntactic wrapper differs. Track A4 will
  harden this with a `nim check` expected-fail shell harness.
- `rkNone` (bounded) push/pop ladder under the unified `Queue`
  (Phase 1, Track B). All four bounded topologies (SPSC, SPMC, MPSC,
  MPMC) route through the typestate verbs from
  `src/lockfreequeues/typestates/` and use `backoffOnRetry` (with
  schedYield escalation at `YieldThreshold`) on CAS-retry paths. Per
  Doc C §3.0: the bounded body field declarations are lifted verbatim
  from the legacy facades, so the typestate verbs continue to compile
  against `head` / `tail` / `(storage | cells)` without change.
- Bounded parity tests under the unified `Queue` shell (Phase 1,
  Track B2). `t_queue_bounded_{sipsic,sipmuc,mupsic,mupmuc}.nim`
  exercise round-trip set equality, FIFO-per-producer, and capacity
  edges through the unified facade; results are byte-for-byte
  identical with the legacy facade.
- `tests/t_queue_bounded_mupmuc_threaded.nim` and
  `tests/t_queue_bounded_sipmuc_threaded.nim` re-enabled (commit
  `232d418`). These were previously disabled with a stale v3.x
  deadlock comment; the v4.0.0 Vyukov bounded protocol rewrite
  closed the underlying race, and the v5.0.0 unified Queue facade
  has the same protocol body.
- Intra-binary bench parity gate. `benchmarks/nim/bench_mpmc.nim`
  split into per-family binaries (`bench_mpmc_mupmuc.nim` +
  `bench_mpmc_sipmuc.nim`) as the B3 bench-binary-layout mitigation
  (commit `37aa1c5`). Co-compiling the Mupmuc grid, the Sipmuc
  shapes, the Queue-bounded parity paths, the Nim channels grid,
  and the MVP comparison adapters into a single release binary was
  producing a -39.6% ± 1.2% throughput artifact on
  `sipmuc/mpmc/1p1c` even though Queue's SPMC pop generated C is
  byte-for-byte identical to the legacy Sipmuc pop. Isolating each
  family into its own binary removes the cross-family iCache
  contention surface at the source. CI matrix (`bench.yml`), local
  runner (`benchmarks/runner.py`), the `nimble benchmarks` task, the
  topology-split deletion-safety tests, and the nightly
  `bench-comparison.yml` crossbeam workflow all enumerate both new
  binaries in place of the pre-split single. MVP comparison adapters
  (boost.lockfree, crossbeam ArrayQueue, threading.Chan) live in the
  mupmuc binary because their slug shape matches the mupmuc grid.
- Smart-constructor shorthands per Doc C §3.0.4 (Step 3.3.5b). Seven
  user-facing helpers wrap the generic `initQueue` (bounded) and
  `newQueue` (unbounded) constructors with per-family fixed
  cardinality, hiding the 10-param phantom suite from the common
  call-site: `newSipsicQueue[T, N]`, `newMupsicQueue[T, N, P]`,
  `newSipmucQueue[T, N, C]`, `newMupmucQueue[T, N, P, C]` (bounded,
  `RK = rkNone`); `newUnboundedMupsicQueue[T, S, MaxThreads]` (borrow
  takes `(mgr, consumerHandle)` to register the single consumer at
  construction, or manager-only `(mgr)` with the consumer registering
  itself later via `attachConsumer()`; auto-create takes `()`),
  `newUnboundedSipmucQueue[T, S, MaxThreads]` and
  `newUnboundedMupmucQueue[T, S, MaxThreads]` (borrow takes `(mgr)`;
  auto-create takes `()`) (unbounded, debra-integrated). (Phase-1 framed
  these as `RK = rkEbr`; 3.3.11-B dropped the `RK` axis — these arms are
  debra-integrated by cardinality.) Initially Doc C §3.0.3 kept
  `UnboundedSipsic` separate in `unbounded_sipsic.nim`; 3.3.11-B
  superseded this by ABSORBING it into `Queue`'s `(ccSingle, ccSingle)`
  arm, and a `newUnboundedSipsicQueue` smart constructor now exists for
  the absorbed SPSC path. A handle-free `ccCons == ccMulti` `newQueue` borrow overload
  is added alongside the smart-constructors to preserve legacy
  `newUnboundedSipmuc(mgr)` and `newUnboundedMupmuc(mgr)` ergonomics
  under the smart-constructor surface; the handle-taking overload
  remains canonical for direct `newQueue` callers.
- rkEbr batch wrappers (Step 3.3.6.5). `QueueProducer.push(openArray[T])`
  and `pop(count: int): Option[seq[T]]` (on `Queue` for ccCons ==
  ccSingle, on `QueueConsumer` for ccCons == ccMulti). Thin loop
  wrappers mirroring the legacy unbounded API
  (`unbounded_mupsic.nim:301-306` and `:383-402`) and the bounded
  counterparts at queue.nim:855-1029. Pure additive; no algorithm
  change; wrappers reuse the existing single-item rkEbr push/pop
  bodies and add no new retire-bearing sites. A
  `Queue.pop(count: int)` trap on bare `Queue` for ccCons == ccMulti
  matches the single-item trap shape.
- Migrated ~290 legacy API call sites across tests + examples to the
  unified Queue generic via the 3.3.5b smart-constructors. Per-family
  bundling preserved bisectability; UnboundedSipsic + its 4 tests
  untouched per §3.0.3 keep-separate decision.

### Documentation (v5.0.0 reframe audit trail)

- Reframe rationale (audit trail): the 2026-05-17 operator decision
  reframed the planned v4.3 MINOR release as a SemVer MAJOR `v5.0.0`
  and collapsed the seven non-SPSC queue families into the unified
  `Queue` generic per the most-correct-least-deferred rule.
- `docs/migration.md` (commit `d6f6244`): full migration guide for
  4.1.x → 5.0.0, including the migration table for every retired
  type and the explicit "no aliases" rule for typed call sites. (The
  doc's two-stage `rkNone` base / `rkEbr` RC release plan was superseded
  by 3.3.11-B — reclamation is cardinality-driven and EBR ships live in
  5.0.0; the `RK` axis no longer exists.)
- Queue-collapse surface specification (audit trail): defined the
  unified `Queue` generic's target shape, uniform generic, param-
  coherence guards, and verbatim source for the bounded and unbounded
  field bodies.
- Cascade inventory and mapping (audit trail): inventoried and mapped
  every legacy-facade call site touched by the unified `Queue` cascade.
  Refactor commits (`c6c9066` umbrella, `5e32dd4` runner, `40fe70b`
  examples, `333b339` benches, `a3b0b4b` adapter consolidation) drew
  from these inventories.
- Track E preflight (audit trail): captured the Task 11 LCRQ baseline
  rename `prevConsumerIdx → consumerHead` as orphan on
  `feat/v4.3-task-14`; the rename was NOT applied to v5.0.0-impl, so
  the unbounded path on v5.0.0-impl is pre-Task-11 state. The
  unbounded debra-integrated body shipped live in 5.0.0 WITHOUT the
  rename; the consumer-claim relaxation carries forward as a v5.x
  post-release semantics change (see L5).
- Phase 4.6 audit-trail clarifications (commit `9cde893`,
  I1+D2+N3): three coordinated docstring / cross-reference fixes
  surfaced by the Phase 4.6 self-review pass. Documented at the
  point of impact so future maintainers see the rationale inline.
- `AGENTS.md` propagation (commit `d0e1996`): the `AGENTS.md`
  pattern established under v4.2/v4.3 (TSAN test-runner hang
  workaround, "Defense placement follows commit placement"
  principle) propagated into v5.0.0-impl audit trail without
  semantic change.

### Known Limitations

The v4.3-no-post-release-deferral rule requires that every limitation
surfaced in a prior release be verdict-classified for the successor
release rather than silently dropped. The 7 limitations carried into
v5.0.0 are below, each with codebase-grounded evidence for the
verdict.

- **L1 — `backoffOnPeerWait` queue-side `schedYield` escalation: (b)
  STILL OPEN.** v4.2.0's Constraint #7 noted that queue-side
  `backoffOnPeerWait` does not escalate to `schedYield`; only the
  harness-side `HarnessBackoff` does. v4.3 took a different shape
  (path-typed split via `backoffOnCASLossRetry`) but that work is
  orphan on `feat/v4.3-task-14` and did NOT propagate to v5.0.0-impl.
  On v5.0.0-impl, `backoffOnPeerWait` remains cpuPause-only
  (`src/lockfreequeues/backoff.nim` line 78), and no queue source
  file calls it (all CAS-retry sites use `backoffOnRetry`, which
  DOES escalate to `schedYield` at `YieldThreshold`). The original
  L1 concern about `backoffOnPeerWait` migration is unaddressed, so
  the limitation carries forward; the unified Queue's CAS-retry
  paths are healthy via `backoffOnRetry`. Resolution path:
  either drop `backoffOnPeerWait` (no callers), give it
  `schedYield` escalation, or document it as cpuPause-only by
  design. Deferred to a v5.x post-release cleanup pass.

- **L2 — `folly_pcq` adapter DROPPED (transitive-include threshold):
  (a) FIXED via removal.** v4.2.0 dropped the `folly_pcq` adapter
  from the comparison set because the transitive-include closure
  (15 unique folly headers) exceeded the 6-header threshold and
  folly main required C++20 vs the repo's C++17. Verification:
  `grep -rn folly_pcq src/ benchmarks/` returns no matches on
  v5.0.0-impl; the adapter file is not present in
  `benchmarks/nim/adapters/`. The decision stands as final.

- **L3 — `LOCKFREEQUEUES_BENCH_STRICT_FLOOR=1` env-var gate: (a)
  FIXED via removal.** v4.2.0 left the strict-floor gate in place
  pending post-merge regeneration of
  `docs/assets/bench-results/latest.json` with the restored
  boost / loony / threading_channels / crossbeam slugs.
  Verification: `grep -rn LOCKFREEQUEUES_BENCH_STRICT_FLOOR
  STRICT_FLOOR .` returns no matches on v5.0.0-impl. The gate has
  been retired; strict-mode is now the de facto default through
  the deletion-safety guard in `superset_check.py` (wired into
  `bench.yml` between `merge_bmf.py` and `bencher run`).

- **L4 — ~65-70% compile-time growth under v4.3 facade-over-
  typestate-verbs pattern: (c) NO LONGER APPLICABLE per reframe.**
  v4.3.0 noted ~65-70% compile-time growth from the v4.3 facade-
  over-typestate-verbs migration of the four unbounded families.
  That migration is orphan on `feat/v4.3-task-14` and did NOT
  propagate to v5.0.0-impl. The v5.0.0 unified `Queue` reframe
  uses a different code-organisation strategy (single generic
  type, `when RK == ...` branches, lifted-verbatim bounded body
  from the legacy facades) so the v4.3 compile-time baseline is
  no longer the reference. The unified Queue's bounded body
  `compiles()` helper (`51f9e47`) and the 9 `validateQueueParams`
  guards (B1+B1.1) shifted the compile-time characteristics
  enough that the v4.3 "65-70% growth" metric is not meaningful
  against v5.0.0. Bench harness measurement is deferred (no
  benches in Phase 4.7 prep scope); compile-time tracking
  resumes as a v5.x post-release optimisation candidate, not a
  v5.0.0 release gate.

- **L5 — Strict-FIFO consumer-claim relaxation (`prevConsumerIdx →
  consumerHead`): (b) STILL OPEN.** v4.3.0 deferred this rename
  and the CAS-on-head consumer-claim mechanism to v4.4. The Task 11
  LCRQ baseline rename is orphan on `feat/v4.3-task-14` and was NOT
  applied to v5.0.0-impl.
  Verification: `prevConsumerIdx` remains the multi-consumer CAS slot
  field name in the shipped `Queue` (`queue.nim`, the `ccCons == ccMulti`
  branches) — the pre-Task-11 state. The unbounded debra-integrated body
  shipped LIVE in 5.0.0, but the strict-FIFO consumer-claim relaxation
  (the `prevConsumerIdx → consumerHead` rename plus CAS-on-head
  mechanism) was NOT included; it carries forward as a v5.x post-release
  semantics change, not a release gate. (There is no v5.0.0 RC — the
  two-stage plan was superseded by 3.3.11-B.)

- **L6 — `neutralizeStalled` mid-call safety caveat (R5): (c) NO
  LONGER APPLICABLE per reframe.** v4.3.0 documented that queue
  push/pop is not safe under `neutralizeStalled` mid-call.
  Verification: `grep -rn neutralizeStalled src/ tests/ docs/`
  returns zero matches on v5.0.0-impl. The function is not part
  of the v5.0.0 public surface, so the safety caveat no longer
  has an API to attach to. If a future release re-introduces
  `neutralizeStalled` (e.g. under Track E's pin-scope work), the
  caveat returns with the function.

- **L7 — Apple Silicon padding test manual-only: (b) STILL OPEN.**
  v4.2.0 and v4.3.0 documented that `tests/t_unbounded_padding.nim`
  runs against the host's `CacheLineBytes` (64 bytes on
  `ubuntu-latest`, 128 bytes on Apple Silicon). The 128-byte path
  runs manually on Apple Silicon hardware rather than as part of
  the CI matrix. Verification: `tests/t_unbounded_padding.nim`
  exists and IS wired into `tests/test.nim` (imported at line 35,
  enumerated at line 64) — so the 64-byte path runs in CI under
  every memory-manager lane. CI for the 128-byte Apple Silicon
  path is not present in `.github/workflows/`. The manual on-device
  run remains the documented procedure. Carries forward as
  STILL OPEN; cross-platform CI for aarch64 is tracked as a v5.x
  post-release infrastructure candidate.

### v4.3 work NOT carried into v5.0.0 (orphan on `feat/v4.3-task-14`)

The unbounded debra-integrated body ships LIVE in v5.0.0 (the multi-
cardinality arms integrate nim-debra 0.8.0 directly). However, a set of
additional v4.3.0 refinements that landed on `feat/v4.3-task-14` (TOCTOU
item-loss fixes for unbounded SPMC / SPSC / MPSC pop at commits `bb50bc9`
and `7296240`; the facade-over-typestate-verbs organization of the four
unbounded families; the orphan SPMC `consumerHeads` field removal — the
field is still present at `queue.nim`, the `ccCons == ccMulti` branch;
14 previously-orphan tests wired into `nimble test`) is NOT on
v5.0.0-impl. Per the operator decision to abandon the v4.2/v4.3 banners
and roll the work into the v5.0.0 narrative, these refinements were NOT
ported into the shipped surface; the original two-stage RC plan that was
to absorb them was superseded by 3.3.11-B (there is no v5.0.0 RC). The
orphan branches remain on the remote as audit-trail artifacts; the
substantive content is a v5.x post-release follow-up that will cite their
commit SHAs when ported. This is consistent with the
v4.3-no-post-release-deferral rule's spirit because the work is not
silently dropped — it is explicitly tracked here as orphan with a named
destination subsystem.

### References

- [Migration guide](docs/migration.md) — full migration table from
  4.1.x to 5.0.0; cited in BREAKING.

## [4.1.0] - 2026-05-01

### Added

- **Auto-create constructors for unbounded MP/SP variants.** `newUnboundedMupmuc[S, T, MaxThreads](strategy)`, `newUnboundedSipmuc[S, T, MaxThreads](strategy)`, and `newUnboundedMupsic[S, T, MaxThreads](strategy)` (the last auto-registers the caller as the consumer). Each heap-allocates a private `DebraManager` owned by the queue; teardown happens inside the queue's `=destroy` after segment cleanup. The existing explicit-manager API (`addr manager`) is preserved for multi-queue setups that share a manager.
- **Auto-register `getProducer()` / `getConsumer()` overloads.** No-arg variants that call `registerThread` internally. Each call consumes one thread slot; threads using multiple queues with a shared manager should prefer the explicit-handle overloads.
- **Bidirectional client refcount on `DebraManager`** (via `nim-debra >= 0.5.0`). Queue constructors call `bindClient`; `=destroy` calls `unbindClient`. The manager's destructor asserts `clientCount == 0`, catching the case where a shared manager is destroyed before its queues.

### Changed

- Bump minimum `debra` to 0.5.0.
- Bump minimum `typestates` to 0.6.0.
- `src/lockfreequeues/atomic_dsl.nim` no longer defines a local `compareExchange` shim — it's now provided by `debra/atomics`.

### Documentation

- `README.md` "Thread safety" section rewritten with the correct explanation of why `ref` items are rejected (`=copy`/`=sink` hooks race on slot refcounts in the shared `array[S, T]`), replacing the prior incorrect spinlock claim.
- "Choosing a queue" table split into separate Bounded and Unbounded tables for better rendering.
- The same `{.error.}` strings inside `unbounded_*.nim` were updated to match.

### Fixed

- `docs/api/epoch.md` removed (referenced a module extracted into `nim-debra`); was breaking the `mkdocs build` step in the docs deploy workflow.
- `.github/workflows/docs.yml` triggers extended to include `devel` branch and `workflow_dispatch`.

## [4.0.0] - 2026-04-30

### BREAKING

- Bounded MPMC/SPMC/MPSC slot protocol switched to per-slot sequence counters (Vyukov bounded-MPMC). Fixes a confirmed race that allowed two consumers to claim the same physical slot across generations, producing silent duplicate-item delivery and producer-vs-producer storage races. The race was TSAN-confirmed at 100% reproduction and ran at roughly a 5% release-mode duplicate rate under contention.
- `Mupmuc`, `Mupsic`, `Sipmuc` types: the `committed*`, `reservedHead*`, `reservedTail*`, and `storage*` fields have been removed. They are replaced with `cells*: MPMCCellArrayN[N, T]`. Consumers introspecting these fields directly must migrate to the new accessors.
- `head` and `tail` cursors on the bounded queue types are now `Atomic[uint64]` instead of `Atomic[int]`. Code reading these via `.load(...)` will need an explicit cast or a local rename.
- Bulk `push(items)` / `pop(count)` semantics have changed. The previous implementation performed an atomic block-claim across the requested range; the new implementation performs a best-effort fill via a loop of singleton operations. Partial completion is reported through the existing `Option[Slice[int]]` / `Option[seq[T]]` return types, so the API surface is unchanged but the intra-call atomicity guarantee is gone.
- `CommittedFlagsN` type removed. Replaced with `SlotSeqN`, `MPMCCellPayload`, and `MPMCCellArrayN`. The `tests/t_committed_flags_n.nim` file has been deleted; equivalent and stronger coverage lives in `tests/t_slot_seq_n.nim`.

### Added

- New `lockfreequeues/backoff` module with `backoffOnRetry` (exponential) and `backoffOnPeerWait` (cpuPause-only) helpers. Used internally on CAS-retry paths to handle CPU oversubscription without burning unbounded CPU.
- Bench harness now supports the `Mupmuc` 8P/8C topology. The previous topology table was implicitly capped at 4P/4C.
- New `LFQ_STRESS_DURATION_SEC` environment variable on threaded stress tests, for sustained-load runs beyond the default iteration budget.
- New `tests/t_slot_seq_generation_rollover.nim`: a deterministic single-threaded reproduction of the original protocol-bug scenario, asserting that the new sequence-counter protocol rejects the stale second-consumer claim.
- Throughput bench harness for `UnboundedMupsic` (1P/1C, 2P/1C, 4P/1C) at `benchmarks/nim/bench_throughput.nim` plus a thin adapter at `benchmarks/nim/adapters/lockfreequeues_unbounded_mupsic.nim` that owns the queue and `DebraManager`. Producer threads register their own `ThreadHandle` in-thread (handles are per-thread by construction). The new variants run for 33 timed iterations + 3 warmup; existing Sipsic/Mupmuc/Channels run counts are unchanged.
- `bench_throughput` accepts variant-group args (`sipsic`, `mupmuc`, `unbounded_mupsic`, `channels`) to limit which benchmarks run. With no args, all variants run (backward compatible). Multiple args take the union of groups. Unknown args print the supported list and exit non-zero. Lets gate runs target a single queue family without paying for the slow bounded MPMC variants.
- Compile-time overrides for `bench_throughput` run shape via `{.intdefine.}` constants: `-d:MessageCount=N`, `-d:DefaultRuns=N`, `-d:WarmupRuns=N`, `-d:UnboundedMupsicRuns=N`, `-d:UnboundedMupsicSegmentSize=N`, `-d:UnboundedMupsicMaxThreads=N`. Defaults are unchanged (1M messages, 33 runs, 3 warmup). Lets gate runs trade statistical confidence for wall-clock budget without source edits. `bench_throughput` also unbuffers stdout in `isMainModule` so progress is visible under file redirect.

### Fixed

- Mupmuc 4P/4C livelock under CPU oversubscription. The combination of new backoff helpers and monotonic per-thread retry counters resolves the scheduler-pressure livelock; the bounded queue can now run 8 contending threads on 4 vCPUs without hangs.
- Bench harness `messageCount div P` truncation bug. Consumers waited forever for items the integer-division truncation had silently discarded. Spread-the-remainder fix applied in three places.
- Several pre-existing breakages in the unbounded threaded stress tests. The 3.2.0 DEBRA migration left them on a deleted `EpochManager` API; the tests have been updated to the current handle-based API. A small number remain disabled pending separate cleanup.

### Changed

- Bounded queue documentation updated to reflect the new sequence-counter publication protocol. Unbounded queue documentation now explicitly disambiguates the segment-local committed-flag protocol from the bounded sequence-counter protocol. See `docs/safety-model.md` and `docs/slot-ownership-typestates.md`.

## [3.2.0] - 2026-04-27

### Added

- New queue types:
  - `Sipmuc`: bounded single-producer, multi-consumer queue.
  - `UnboundedSipsic`: segmented unbounded single-producer, single-consumer queue (no reclamation needed).
  - `UnboundedSipmuc`: segmented unbounded single-producer, multi-consumer queue with DEBRA reclamation.
  - `UnboundedMupsic`: segmented unbounded multi-producer, single-consumer queue with DEBRA reclamation.
  - `UnboundedMupmuc`: segmented unbounded multi-producer, multi-consumer queue with DEBRA reclamation.
  - Segment storage uses libc `c_calloc` / `c_free` (via `system/ansi_c`); a nil return from `c_calloc` raises `OutOfMemDefect`. Avoids the cross-thread free hazard from Nim's `allocShared`, which routes through per-thread heap metadata.
  - The consumer-visible head pointer is `Atomic[ptr Segment]` and is CAS-advanced past exhausted segments; the CAS winner retires the old segment via DEBRA.
- Typestate-driven push and pop modules under `src/lockfreequeues/typestates/` for both bounded and unbounded queues. The high-level queue APIs now build on these typestate transitions.
- `DeallocationStrategy` (`Manual` / `Eager`) on the unbounded queues, configured at queue construction. `Eager` retires and immediately attempts reclamation per pop; `Manual` accumulates retired segments for an external `tryReclaim` call. Default is `Eager`, except `Manual` under `--gc:none`.
- Compile-time `-d:LockFreeQueuesAdvanceEvery=N` (default 64) to tune the per-pop epoch-advance cadence in the unbounded queue retirement paths.
- Compile-time lock-free check for queue item types: arc/orc compilation errors when a queue holds `ref` items (which fall back to spinlock refcounting on those memory managers). Opt out with `-d:allowNonLockFreeQueueItems`.
- Threaded reclamation tests for all four unbounded queue variants (`t_unbounded_*_threaded`), exercised under arc, orc, and refc, plus the TSAN and ASAN sanitizer matrix.
- Latency and throughput benchmark suite under `benchmarks/nim/` (`bench_latency.nim`, `bench_throughput.nim`, `bench_main.nim`) with adapters for each queue type.
- New examples: `audio_buffer.nim`, `event_collector.nim`, `job_scheduler.nim`, `task_fanout.nim`, and `sipmuc.nim`.
- Thread safety section and slot-ownership typestate documentation in README.
- CI matrix across arc, orc, and refc memory managers.
- Dependency on `debra >= 0.3.0` for safe memory reclamation in the unbounded multi-consumer queues.
- Dependency on `typestates >= 0.3.1` (already used; bumped to pull in the latest API).

### Changed

- Eager-strategy unbounded queues now gate `reclaimNow` on `advanceEvery` returning `true`, eliminating per-pop epoch-safety atomic loads when the global epoch hasn't advanced. Reclamation latency is bounded by `LockFreeQueuesAdvanceEvery` (default 64), the same cadence the user already controls.
- Bounded queues (`Sipsic`, `Mupsic`, `Mupmuc`) reimplemented on the typestate layer. SPSC uses N+1 storage slots to distinguish empty from full; MPSC, SPMC, and MPMC use N storage slots paired with per-slot committed flags so producers can publish before consumers observe the slot. Surface API (push/pop, `head`/`tail`, capacity semantics) is unchanged for SPSC; the multi-producer / multi-consumer variants gain a published-before-visible ordering guarantee they did not previously provide.
- `atomic_dsl.nim` now re-exports `debra/atomics` instead of wrapping `std/atomics`. Call-site DSL (`relaxed`, `acquire`, `release`, `sequential`) is unchanged.
- Stress test runner exercises all three memory managers.

### Removed

- `std/atomics` dependency. `Atomic[T]` and the memory-order primitives are now sourced from `debra/atomics`.
- `src/lockfreequeues/constants.nim`. `CacheLineBytes` is now sourced from `debra/atomics`.
- Removed the internal `lockfreequeues/ops` submodule. It was documented as internal, had no callers inside the library, and its `index` helper had silently shifted from `value mod capacity` (3.1.0) to `value mod (capacity + 1)` during the queue refactor. External code that imported `lockfreequeues/ops` directly should migrate to the public typestate API or inline the small helpers it contained.

## [3.1.0] - 2024-09-28

### Changed

- Fixed wraparound issue in `full()`
- Drop support for Nim v1 due to compilation issue with atomics.

## [3.0.0] - 2021-12-14

### Added

- README link to Gitter chat room.

### Changed

- Regenerate documentation on PR merge.
- Test against Nim 1.6.0.
- Convert `NoConsumersAvailableDefect` and `NoProducersAvailableDefect` to `CatchableErrors`; there might be some value in catching them.

### Removed

## [2.1.0] - 2021-07-19

### Added

### Changed

- Use correct memory orderings, as reported in https://github.com/elijahr/lockfreequeues/issues/6
- Move changelog from README.md to CHANGELOG.md

### Removed

## [2.0.6] - 2021-01-25

### Added

### Changed

- Fix issue with htmldocs submodule during `nimble install lockfreequeues`.

### Removed

## [2.0.5] - 2021-01-06

### Added

### Changed

- Moved from Travis CI to GitHub Actions.

### Removed

## [2.0.4] - 2020-08-10

### Added

- Multi-producer, single-consumer queue (Mupsic)
- Multi-producer, multi-consumer queue (Mupmuc)
- Nicer examples

### Changed

- Refactor
- Fix wrap-around bug, improve test coverage

### Removed

- Shared memory queues

## [1.0.0] - 2020-07-06

### Added

### Changed

- Addresses feedback from [#1](https://github.com/elijahr/lockfreequeues/issues/1)
- `head` and `tail` are now in the range `0 ..<2*capacity`
- `capacity` doesn’t have to be a power of two
- Use `align` pragma instead of padding array

### Removed

## [0.1.0] - 2020-07-02

### Added

- Initial release, containing `SipsicSharedQueue` and `SipsicStaticQueue`

### Changed

### Removed
