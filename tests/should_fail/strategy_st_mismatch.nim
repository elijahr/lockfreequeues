## §6.3 condition (1): Consumer with ST=stManual cannot be constructed
## from Queue with ST=stEager.
##
## A `getConsumer` call on a `Queue[..., stEager, ...]` returns a
## `QueueConsumer[..., stEager, ...]`. Passing that result to a proc
## that constrains ST=stManual must fail type-checking with a
## type-mismatch error.

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

# A proc that only accepts a stManual consumer view. Calling this with
# the result of `q.getConsumer()` from a stEager queue must fail at
# type-check.
proc requireManualConsumer[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    RK: static ReclamationKind,
    N, P, C, S, MaxThreads: static int,
](_: QueueConsumer[T, ccProd, ccCons, stManual, RK, N, P, C, S, MaxThreads]) =
  discard

proc main() =
  var q = newUnboundedMupmucQueue[int, stEager, 16, 4]()
  var c = q.getConsumer()
  requireManualConsumer(c)

main()
