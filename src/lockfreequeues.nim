## lockfreequeues — top-level umbrella module.
##
## v5.0.0 final shape (3.3.11-B.2.5):
##   - Bounded surface: `BQueue[T, ccProd, ccCons, N, P, C]` in
##     `lockfreequeues/bqueue`.
##   - Unbounded surface: `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
##     in `lockfreequeues/queue`. The `(ccSingle, ccSingle)` branch
##     absorbs what was the standalone `UnboundedSipsic[S, T]` type
##     (debra-free, committed-flag-free linked-segment protocol).
##   - Strategy / reclamation / pinscope-stub enums re-exported for
##     consumer code that references `stEager`, `stManual`, `ccSingle`,
##     `ccMulti` (and the legacy `rkNone`/`rkEbr` symbols) directly.
##   - `unbounded_sipsic` module deleted in B.2.5 (absorbed into Queue).

when compileOption("threads"):
  import
    ./lockfreequeues/[atomic_dsl, bqueue, exceptions, queue, reclamation, strategy]
  import ./lockfreequeues/internal/pinscope_stub

  export atomic_dsl, bqueue, exceptions, queue, reclamation, strategy
  export pinscope_stub
else:
  # threading off, only provide the unified Queue + its supporting enums
  # (Queue SPSC works without threads).
  import ./lockfreequeues/[atomic_dsl, bqueue, queue, reclamation, strategy]
  import ./lockfreequeues/internal/pinscope_stub

  export atomic_dsl, bqueue, queue, reclamation, strategy
  export pinscope_stub
