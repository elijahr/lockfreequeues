discard """
  errormsg: "SpscProducerTag"
"""
## C9 tripwire (b): pop on a Bound[T, SpscProducerTag, ...] endpoint
## must reject at the pop proc signature itself — pop is constrained
## `Tag: SpscConsumerTag | MpmcConsumerTag | AnyThreadTag`.

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

var q: BQueue[int, ccSingle, ccMulti, 64, 0, 4]
var wrongTagBound: Bound[int, SpscProducerTag, typeof(q)]
wrongTagBound.queue = addr q
discard wrongTagBound.pop()
  # MUST FAIL: SpscProducerTag doesn't satisfy the consumer Tag constraint.
