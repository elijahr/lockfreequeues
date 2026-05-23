## 3.3.11-B.4.1.6 Bundle F deferred-from-B.3 J case (11):
## ccSingle BQueueConsumer cannot call `attach()`.
##
## Symmetric to `bqueue_producer_attach_ccsingle.nim` — Wall 2 fix
## (B.4.1.5) gates consumer-side `attach` to `ccCons == ccMulti` only.
## A ccSingle consumer has no overload and the diagnostic must
## reference the user-visible `BQueueConsumer` alias (M5 R9).

import lockfreequeues/bqueue

proc main() =
  var q = newSipsicQueue[int, 8]()
  var c: BQueueConsumer[int, ccSingle, ccSingle, 8, 0, 0]
  c.queue = addr q
  c.attach()  # EXPECTED COMPILE ERROR

main()
