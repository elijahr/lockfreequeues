import std/[unittest, options]
import lockfreequeues/queue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "queue push/pop on Bound":
  test "SPSC unbounded: push and pop through Bound endpoints":
    var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
    var bp = q.getProducer().bindToThread()
    bp.push(1)
    bp.push(2)
    var bc = q.getConsumer().bindToThread()
    let a = bc.pop()
    let b = bc.pop()
    check a.isSome and a.get == 1
    check b.isSome and b.get == 2
