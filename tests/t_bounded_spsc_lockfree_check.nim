## Test that bounded SPSC BQueue rejects non-lock-free types at compile-time.
##
## This test should FAIL compilation on arc/orc/atomicArc without
## -d:allowNonLockFreeQueueItems.
##
## Mirrors `tests/t_unbounded_spsc_lockfree_check.nim`, but exercises
## the bounded surface (`BQueue` via `newSpscQueue`) and the BQueue-
## family ref-T guard added on every single-item push/pop overload of
## `src/lockfreequeues/bqueue.nim`.

import ../src/lockfreequeues/bqueue

type Node = ref object
  value: int

var queue = newSpscQueue[Node, 16]()

# This should error on arc/orc/atomicArc with the BQueue-family guard.
var n: Node = nil
discard queue.push(n)

echo "If you see this, either on refc or used -d:allowNonLockFreeQueueItems"
