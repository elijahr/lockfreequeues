## Deallocation strategy enum for the v5.0.0 unified `Queue` generic.
##
## Consolidates the triplicated `DeallocationStrategy` enum that previously
## lived in `unbounded_mupsic.nim`, `unbounded_sipmuc.nim`, and
## `unbounded_mupmuc.nim`. v4.x callers used the bare-symbol forms `Manual`
## and `Eager`; those are preserved as constant aliases (Doc C §3.1) so the
## migration to the prefixed `stManual` / `stEager` is non-breaking at the
## call site.
##
## Doc C §3.1, §5 (verbatim source).

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
