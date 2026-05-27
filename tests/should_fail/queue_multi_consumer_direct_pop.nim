## §6.3 condition (8) / 3.3.11-B Bundle J + M8 (family-level):
## direct `pop` on a multi-consumer unbounded `Queue` is gated by a
## Bundle E `{.error.}` overload. Calling `pop()` on a
## `ccCons == ccMulti` Queue must fail at compile time with a message
## pointing the caller at `Queue.getConsumer().pop()`.
##
## M8 light-touch coverage: this is the multi-consumer family proof
## for the unbounded surface. Both `newUnboundedSpmcQueue` and
## `newUnboundedMpmcQueue` thin-wrappers resolve to a
## `ccCons == ccMulti` Queue, so the same `{.error.}` overload fires.

import std/options
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub

proc main() =
  # Auto-create overload: ccCons=ccMulti unbounded Queue.
  var q = newUnboundedSpmcQueue[int, stEager, 16, 4]()
  # Direct pop on ccCons=ccMulti Queue must compile-fail.
  discard q.pop()

main()
