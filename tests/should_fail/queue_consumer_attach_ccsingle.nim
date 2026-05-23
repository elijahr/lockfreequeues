## 3.3.11-B.4.1.6 Bundle F deferred-from-B.3 J case (13):
## ccSingle QueueConsumer cannot call `attach()`.

import lockfreequeues/queue

proc main() =
  var q = newUnboundedSipsicQueue[int, Manual, 8, 4]()
  var c: QueueConsumer[int, ccSingle, ccSingle, Manual, 8, 4]
  c.queue = addr q
  c.attach()  # EXPECTED COMPILE ERROR

main()
