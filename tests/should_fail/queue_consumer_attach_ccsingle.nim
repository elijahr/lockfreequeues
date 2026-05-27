
## ccSingle QueueConsumer cannot call `attach()`.

import lockfreequeues/queue

proc main() =
  var q = newUnboundedSpscQueue[int, Manual, 8, 4]()
  var c: QueueConsumer[int, ccSingle, ccSingle, Manual, 8, 4]
  c.queue = addr q
  c.attach()  # EXPECTED COMPILE ERROR

main()
