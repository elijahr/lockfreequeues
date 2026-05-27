
## direct `pop` on a multi-consumer `BQueue` is gated by a
## `{.error.}` overload. Calling `pop()` on a `ccCons == ccMulti`
## BQueue must fail at compile time with a message pointing the caller
## at `BQueue.getConsumer().pop()`.
##
## M8 light-touch coverage: this is the multi-consumer family proof.
## Both `newSpmcQueue` and `newMpmcQueue` thin-wrappers resolve to
## a `ccCons == ccMulti` BQueue, so the same `{.error.}` overload fires
## for them.

import std/options
import lockfreequeues/bqueue

proc main() =
  var q = newSpmcQueue[int, 8, 4]()
  # Direct pop on ccCons=ccMulti BQueue must compile-fail.
  discard q.pop()

main()
