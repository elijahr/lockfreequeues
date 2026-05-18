# v4.3 → v5.0.0 Reframe Rationale

## Why this document exists

`lockfreequeues` started 2026-Q2 with a planned **v4.3 MINOR** release that
would land the `PinnedScope` + `retireOnCAS` migration of the five
unbounded `withPin` sites, consolidate the duplicated
`DeallocationStrategy` enum into a shared module, and lift the runtime
`strategy:` field to a compile-time phantom. As v4.3 implementation
progressed, the cascade surface area kept growing — each phantom lift
exposed adjacent typestate-family asymmetries that themselves wanted
phantoms, the per-family verbs (`initMupsic`, `newUnboundedMupmuc`, ...)
multiplied phantom positions without unifying the underlying type
algebra, and the implied `Mupsic` / `Sipmuc` / ... alias surface around
each variant became a second source of cardinality information that
could disagree with the phantom.

The operator decision on 2026-05-17 reframed the release as a SemVer
**MAJOR** (`v5.0.0`) and collapsed the seven non-SPSC queue families
into a single unified `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S,
MaxThreads]` generic. Under the no-alias rule, every typed call site
migrates mechanically; cardinality, deallocation strategy, and
reclamation kind are exposed as explicit phantoms on the unified type.
The cascade no longer fights a multi-family alias surface — there is
one type to reason about, one set of method bodies that branch via
`when RK == rkNone` / `when RK == rkEbr` and `when ccProd == ...` /
`when ccCons == ...`, and one migration table for adopters. The
audit-trail purpose of this file is to document that inflection point
per the most-correct-least-deferred rule: structural reframes deserve
captured rationale so future maintainers (and the v6 design pass)
inherit the decision context rather than re-deriving it from commit
history.

## What rolled in from v4.3

The reframe **kept** the v4.3 deliverables that survived the structural
shift:

- **The `DeallocationStrategy` consolidation.** The three identical enum
  definitions at `unbounded_mupsic.nim:52`, `unbounded_mupmuc.nim:50`,
  and `unbounded_sipmuc.nim:54` collapse into the new shared module
  `src/lockfreequeues/strategy.nim` (Doc C §3.1).
- **The strategy-phantom lift.** The runtime `strategy:` field on every
  `Unbounded*` queue is removed; `ST` is now a static phantom on `Queue`
  with `stManual` / `stEager` monomorphizing separately. The legacy
  `Manual` / `Eager` enum values stay exported as `const` aliases for
  grep continuity (Doc C §2.5, §3.2).
- **The `PinnedScope` + `retireOnCAS` migration of the five `withPin`
  sites.** The three retire-bearing pop paths and two producer-push
  pin-only paths route through the new per-queue
  `q.retireOnCAS(...)` / `q.retireOnPublish(...)` wrappers, gated on
  `RK = rkEbr` per Doc C §3.0.2.
- **The cardinality-phantom cascade.** `ccProd` / `ccCons` thread
  through `ThreadHandle[MaxThreads, CC]` on every queue field,
  `Producer*`, and `Consumer*` object, including the 6 debra-aware
  typestate scaffolding files. The other 19 typestate scaffolding files
  remain untouched.

## What was dropped

- **`folly_pcq` as a planned addition.** The folly-style port of the
  producer-consumer queue was on the v4.3 stretch list (L2). Under the
  v5.0.0 reframe its design pre-dates the unified-`Queue` algebra and
  would either re-introduce a per-family verb surface or require its
  own retrofit pass through the new phantom layout. Dropped from the
  v5.0.0 release scope.
- **The per-typestate facade-over-verbs pattern.** Pre-reframe v4.3
  planning explored exposing each family (`Mupsic`, `Sipmuc`, ...) as a
  facade type whose constructor / methods routed to a shared
  implementation while preserving the family-named public API. Under
  the unified `Queue` generic with the no-alias rule, the facade
  pattern is precisely the implicit-cardinality channel the unification
  is meant to eliminate. Dropped.

## What was added

- **The unified `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S,
  MaxThreads]` 10-param generic.** One type, one set of method bodies,
  one migration table. `UnboundedSipsic[S, T]` is intentionally kept
  separate per Doc C §3.0.3 (no retire-race; SPSC; forcing it into the
  generic would either waste runtime on unused EBR ops or require a
  second unbounded body in the `when` ladder).
- **The nine `validateQueueParams` static guards** (Doc C §3.0.2.4).
  Each `when RK == ...` branch of the type body carries `static:
  assert` checks that fail at the caller's instantiation site if the
  supplied size-param set is incoherent — `rkEbr` with `S = 0`,
  `rkNone` with `S > 0`, `ccMulti` with the corresponding cardinality
  slot at `0`, etc. The assertions are inside the `when RK` branches
  (so each branch's guards run only when that branch is selected) and
  carry plain-English messages naming the offending parameter. This
  preserves the instantiation-time quality-of-error that the legacy
  per-family types provided despite the 10-position generic surface.
  No runtime cost, no codegen change.
- **`ReclamationKind` (`rkNone` / `rkEbr`) as a load-bearing phantom.**
  Selects bounded (Vyukov seq counters) vs unbounded (LCRQ-style
  segmented + nim-debra reclamation) field layout and method bodies via
  `when RK ==`.
- **`PinScopeCardinality` (`ccSingle` / `ccMulti`)** threaded through
  `ThreadHandle[MaxThreads, CC]` on every queue, producer, and
  consumer reference in the debra-aware paths.
- **The intra-binary bench parity gate** replacing the literal-HALT
  pattern. The v4.x bench harness used a literal-HALT detector to
  catch regressions; the v5.0.0 parity gate compares the unified-Queue
  bench numbers against the pre-collapse baseline within the same
  binary, eliminating the cross-binary noise that made literal-HALT
  brittle.

## See also

- `docs/v5.0.0-migration/design-queue-collapse-v5.0.0-20260516.md` —
  the authoritative v5.0.0 design document. Section 1 carries the
  release-goal framing; section 3.0.2.4 specifies the static-assert
  guard set; section 5 carries the migration table reproduced in
  `docs/migration.md`.
- `docs/migration.md` — the user-facing 8-pre-forms → unified-Queue
  migration guide.
