
## direct batch `push` on a multi-producer `BQueue` is gated by a
## `{.error.}` overload. Calling `push(items)` on a `ccProd == ccMulti`
## BQueue must fail at compile time with a message pointing the caller
## at `BQueue.getProducer().push(items)`.

import std/options
import lockfreequeues/bqueue

proc main() =
  var q = newMpmcQueue[int, 8, 4, 4]()
  let items = @[1, 2, 3]
  # Direct batch push on ccProd=ccMulti BQueue must compile-fail.
  discard q.push(items)

main()
