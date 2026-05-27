
## ccSingle BQueueConsumer cannot call `attach()`.
##
## Symmetric to `bqueue_producer_attach_ccsingle.nim` — 
##  gates consumer-side `attach` to `ccCons == ccMulti` only.
## A ccSingle consumer has no overload and the diagnostic must
## reference the user-visible `BQueueConsumer` alias.

import lockfreequeues/bqueue

proc main() =
  var q = newSpscQueue[int, 8]()
  var c: BQueueConsumer[int, ccSingle, ccSingle, 8, 0, 0]
  c.queue = addr q
  c.attach()  # EXPECTED COMPILE ERROR

main()
