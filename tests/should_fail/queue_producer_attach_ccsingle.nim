## ccSingle QueueProducer cannot call `attach()`.
##
## Same shape as the BQueue counterpart, but exercising the
## QueueClaimState typestate on the unbounded Queue's view types.

import lockfreequeues/queue

proc main() =
  var q = newUnboundedSpscQueue[int, Manual, 8, 4]()
  var p: QueueProducer[int, ccSingle, ccSingle, Manual, 8, 4]
  p.queue = addr q
  p.attach() # EXPECTED COMPILE ERROR

main()
