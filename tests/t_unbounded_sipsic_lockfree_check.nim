## Test that UnboundedSipsic rejects non-lock-free types at compile-time.
##
## This test should FAIL compilation on arc/orc without -d:allowNonLockFreeQueueItems.

import ../src/lockfreequeues/unbounded_sipsic

type Node = ref object
  value: int

# This should error on arc/orc
var queue = newUnboundedSipsic[64, Node]()

echo "If you see this, either on refc or used -d:allowNonLockFreeQueueItems"
