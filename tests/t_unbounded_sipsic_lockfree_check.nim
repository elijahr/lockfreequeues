## Test that UnboundedSipsic rejects non-lock-free types at compile-time.
##
## This test should FAIL compilation on arc/orc without -d:allowNonLockFreeQueueItems.
##
## Post-3.3.11-B.2.5: the standalone `UnboundedSipsic[S, T]` was absorbed
## into `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`. The
## ref-type guard now triggers on push, not on construction.

import ../src/lockfreequeues/queue
import ../src/lockfreequeues/strategy
import ../src/lockfreequeues/internal/pinscope_stub

type Node = ref object
  value: int

var queue = newUnboundedSipsicQueue[Node, stEager, 64, 4]()
var p = queue.getProducer()

# This should error on arc/orc
var n: Node = nil
p.push(n)

echo "If you see this, either on refc or used -d:allowNonLockFreeQueueItems"
