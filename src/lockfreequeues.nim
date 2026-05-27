## lockfreequeues — top-level umbrella module.
##
## The umbrella module exposes `LockfreequeuesVersion` so the bench
## harness's `getAdapterVersions` can stamp the in-tree package version
## into the bench JSON `meta.adapters.lockfreequeues.version` field
## without re-parsing `lockfreequeues.nimble` at run time.
## Source-of-truth remains `lockfreequeues.nimble`; this constant MUST
## be bumped in lockstep on every release.

const LockfreequeuesVersion* {.strdefine.} = "5.0.0"
  ## In-tree package version. Mirrors the `version = "5.0.0"` line in
  ## `lockfreequeues.nimble`. `{.strdefine.}` lets downstream builds
  ## override via `-d:LockfreequeuesVersion=<x.y.z>` for fork builds; the
  ## bench JSON captures whatever value was compiled in.

##
## Original module contract:
##   - Bounded surface: `BQueue[T, ccProd, ccCons, N, P, C]` in
##     `lockfreequeues/bqueue`.
##   - Unbounded surface: `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
##     in `lockfreequeues/queue`. The `(ccSingle, ccSingle)` branch
##     absorbs what was the standalone `UnboundedSpsc[S, T]` type
##     (debra-free, committed-flag-free linked-segment protocol).
##   - Strategy / reclamation / pinscope-stub enums re-exported for
##     consumer code that references `stEager`, `stManual`, `ccSingle`,
##     `ccMulti` (and the legacy `rkNone`/`rkEbr` symbols) directly.

when compileOption("threads"):
  import debra/atomics
  import debra/atomics/dsl
  import
    ./lockfreequeues/[bqueue, exceptions, queue, reclamation, strategy]
  import ./lockfreequeues/internal/pinscope_stub

  export atomics, dsl
  export bqueue, exceptions, queue, reclamation, strategy
  export pinscope_stub
else:
  # threading off, only provide the unified Queue + its supporting enums
  # (Queue SPSC works without threads).
  import debra/atomics
  import debra/atomics/dsl
  import ./lockfreequeues/[bqueue, queue, reclamation, strategy]
  import ./lockfreequeues/internal/pinscope_stub

  export atomics, dsl
  export bqueue, queue, reclamation, strategy
  export pinscope_stub
