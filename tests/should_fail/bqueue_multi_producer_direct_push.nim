## §6.3 condition (6) / 3.3.11-B Bundle J + M8 (family-level):
## direct `push` on a multi-producer `BQueue` is gated by a Bundle E
## `{.error.}` overload. Calling `push(item)` on a `ccProd == ccMulti`
## BQueue must fail at compile time with a message pointing the caller
## at `BQueue.getProducer().push(item)`.
##
## M8 light-touch coverage: this is the multi-producer family proof.
## The thin-wrapper `newMupsicQueue` family resolves to
## `newBQueue[..., ccMulti, ccSingle, ...]()`, so the same `{.error.}`
## overload fires for it.

import lockfreequeues/bqueue

proc main() =
  var q = newMupsicQueue[int, 8, 4]()
  # Direct push on ccProd=ccMulti BQueue must compile-fail.
  discard q.push(42)

main()
