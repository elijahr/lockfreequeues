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
##     enum lives here pending Track E re-home into debra 0.8.0; task
##     #94 retires the stub as a separate cleanup step).
##   - Re-exports `unbounded_sipsic` per Doc C §3.0.3 keep-separate.
##
## Step 3.3.7b deleted the 7 legacy per-family src modules (`sipsic`,
## `mupsic`, `sipmuc`, `mupmuc`, `unbounded_mupsic`, `unbounded_sipmuc`,
## `unbounded_mupmuc`) now that 3.3.6 migrated all typed call sites to
## the unified Queue API and 3.3.7a-prep relocated the load-bearing
## introspection helpers from the unbounded legacy modules into
## queue.nim. Their re-exports below are correspondingly removed.
## UnboundedSipsic stays per Doc C §3.0.3.

when compileOption("threads"):
  import
    ./lockfreequeues/[
      atomic_dsl, exceptions, queue, reclamation, strategy, unbounded_sipsic,
    ]
  import ./lockfreequeues/internal/pinscope_stub

  export
    atomic_dsl, exceptions, queue, reclamation, strategy, unbounded_sipsic
  export pinscope_stub
else:
  # threading off, only provide the unified Queue + its supporting enums
  # (Queue SPSC works without threads). The legacy `sipsic` module is
  # deleted in 3.3.7b; SPSC behaviour is now reached via the unified
  # Queue type itself.
  import ./lockfreequeues/[atomic_dsl, queue, reclamation, strategy]
  import ./lockfreequeues/internal/pinscope_stub

  export atomic_dsl, queue, reclamation, strategy
  export pinscope_stub
