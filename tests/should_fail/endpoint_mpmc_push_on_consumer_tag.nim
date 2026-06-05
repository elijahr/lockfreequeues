discard """
  errormsg: "MpmcConsumerTag"
"""
## C9 tripwire (d): MPMC equivalent of (a). Push on a
## Bound[T, MpmcConsumerTag, ...] endpoint must reject because the push
## Tag-constraint excludes consumer tags.

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

var q: BQueue[int, ccMulti, ccMulti, 64, 4, 4]
var wrongTagBound: Bound[int, MpmcConsumerTag, typeof(q)]
wrongTagBound.queue = addr q
discard wrongTagBound.push(1) # MUST FAIL: MpmcConsumerTag != producer-side tag.
