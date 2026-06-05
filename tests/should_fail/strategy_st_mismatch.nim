## §6.3 condition (1): Consumer with ST=stManual cannot be constructed
## from Queue with ST=stEager.
##
## Track C v5.0.0 update: the receiver is now `Unbound[T, AnyThreadTag,
## Queue[T, ccProd, ccCons, stManual, S, MaxThreads]]` rather than the
## deleted `QueueConsumer`. The phantom-param mismatch still trips at
## type-check because the Queue's `ST` doesn't match.

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

# A proc that only accepts a stManual endpoint. Calling this with the
# result of `q.getConsumer()` from a stEager queue must fail at type-check.
proc requireManualConsumer[
    T; ccProd, ccCons: static PinScopeCardinality, S, MaxThreads: static int
](_: Unbound[T, AnyThreadTag, Queue[T, ccProd, ccCons, stManual, S, MaxThreads]]) =
  discard

proc main() =
  var q = newUnboundedMpmcQueue[int, stEager, 16, 4]()
  let c = q.getConsumer()
  requireManualConsumer(c)

main()
