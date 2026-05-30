discard """
  errormsg: "SpscConsumerTag"
"""
## C9 tripwire (a): push on a Bound[T, SpscConsumerTag, ...] endpoint
## must reject at the push proc signature itself — push is constrained
## `Tag: SpscProducerTag | MpmcProducerTag | AnyThreadTag`, so a
## consumer-side tag fails the generic constraint at the call site
## (NOT via wrapper-proc indirection).

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

var q: BQueue[int, ccMulti, ccSingle, 64, 4, 0]
var wrongTagBound: Bound[int, SpscConsumerTag, typeof(q)]
wrongTagBound.queue = addr q
discard wrongTagBound.push(1)
  # MUST FAIL: SpscConsumerTag doesn't satisfy the producer Tag constraint.
