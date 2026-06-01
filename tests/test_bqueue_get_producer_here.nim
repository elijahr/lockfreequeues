import std/[unittest, options]
import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "getProducerHere / getConsumerHere (BQueue)":
  test "MPMC: shortcut returns Bound[AnyThreadTag] + push works":
    var q: BQueue[int, ccMulti, ccMulti, 64, 4, 4]
    var bp = q.getProducerHere()
    check bp.push(7)
    var bc = q.getConsumerHere()
    let got = bc.pop()
    check got.isSome and got.get == 7
