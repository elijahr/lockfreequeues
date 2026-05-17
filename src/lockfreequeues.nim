## lockfreequeues — top-level umbrella module.
##
## v5.0.0 cascade migration (Track D3.1):
##   - Re-exports the unified `Queue[T, ccProd, ccCons, ST, RK, N, P, C,
##     S, MaxThreads]` generic (from `lockfreequeues/queue`) plus its
##     `initQueue`, `newQueue`, `getProducer`, `getConsumer`, `push`,
##     `pop`, `capacity`, `producerCount`, `consumerCount` API.
##   - Re-exports the strategy and reclamation enum modules so consumer
##     code can reference `stEager`, `stManual`, `rkNone`, `rkEbr`,
##     `ccSingle`, `ccMulti` without depending on the queue submodule
##     directly.
##   - Re-exports `internal/pinscope_stub` (the `PinScopeCardinality`
##     enum lives here pending Track E re-home into debra 0.8.0).
##   - KEEPS the legacy per-family re-exports (mupmuc, mupsic, sipmuc,
##     sipsic, unbounded_mupmuc, unbounded_mupsic, unbounded_sipmuc,
##     unbounded_sipsic) for the duration of the cascade. Track F5
##     deletes the four bounded source modules and their re-exports
##     here; Manager D-late-unbounded migrates unbounded consumers and
##     Track F5 deletes the unbounded re-exports (except
##     `unbounded_sipsic` per Doc C §3.0.3 carve-out).

when compileOption("threads"):
  import
    ./lockfreequeues/[
      atomic_dsl, exceptions, queue, reclamation, strategy,
      mupmuc, mupsic, sipmuc, sipsic, unbounded_mupmuc,
      unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic,
    ]
  import ./lockfreequeues/internal/pinscope_stub

  export
    atomic_dsl, exceptions, queue, reclamation, strategy,
    mupmuc, mupsic, sipmuc, sipsic, unbounded_mupmuc,
    unbounded_mupsic, unbounded_sipmuc, unbounded_sipsic
  export pinscope_stub
else:
  # threading off, only provide sipsic + the unified Queue + its
  # supporting enums (Queue SPSC works without threads).
  import ./lockfreequeues/[atomic_dsl, queue, reclamation, strategy, sipsic]
  import ./lockfreequeues/internal/pinscope_stub

  export atomic_dsl, queue, reclamation, strategy, sipsic
  export pinscope_stub
