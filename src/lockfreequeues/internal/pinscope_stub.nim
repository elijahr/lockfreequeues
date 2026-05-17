## MODE-(a) STUB — pin-scope cardinality phantom.
##
## In v5.0.0 the canonical home of `PinScopeCardinality` is nim-debra
## 0.8.0 (re-exported per Doc B §3.4.1 and consumed by lockfreequeues
## per Doc C IC-5). At the time Track A1+A2 lands, guava's nim-debra
## 0.8.0 worktree has not yet been linked via `nimble develop`, so
## `import debra` does not resolve to the 0.8.0 type surface.
##
## To unblock the v5.0.0 Queue type shell without taking a dependency on
## guava's in-flight work, this file declares a LOCAL placeholder
## `PinScopeCardinality` enum with the same member identifiers
## (ccSingle, ccMulti) the 0.8.0 surface will expose.
##
## **Removal protocol** (Manager E, Task E1 / E2):
##   1. Once `nimble develop` resolves `import debra` to nim-debra 0.8.0,
##      add `export PinScopeCardinality, ccSingle, ccMulti` to
##      `src/lockfreequeues/queue.nim` from `import debra` (or
##      `import debra/handles` per Doc B's final module layout).
##   2. Delete this file.
##   3. Update `queue.nim` to import the cardinality enum from debra
##      instead of from `internal/pinscope_stub`.
##   4. Tests should still pass — the member identifiers are stable.
##
## DO NOT add fields or methods to this enum. It exists only to give the
## v5.0.0 Queue shell a parseable type for its `ccProd: static
## PinScopeCardinality` and `ccCons: static PinScopeCardinality`
## generic params during the Track A → Track E handoff window.
##
## Doc C IC-5 (cardinality enum is debra-owned), Doc B §3.4.1.

type PinScopeCardinality* = enum
  ccSingle   ## Single-thread cardinality marker for a pinned scope.
  ccMulti    ## Multi-thread cardinality marker for a pinned scope.
