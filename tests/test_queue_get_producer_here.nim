import std/[unittest, options]
import lockfreequeues/queue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "getProducerHere / getConsumerHere / bindConsumer (Queue)":
  test "SPSC unbounded: shortcuts work":
    var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
    var bp = q.getProducerHere()
    bp.push(42)
    var bc = q.getConsumerHere()
    let got = bc.pop()
    check got.isSome and got.get == 42

  test "MPSC unbounded: bindConsumer one-shot wrapper":
    var q = newUnboundedMpscQueue[int, stEager, 16, 4]()
    var bc = q.bindConsumer()
    check bc.handleManager != nil # debra-integrated; registered
