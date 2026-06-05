import std/unittest
import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "bqueue endpoint compile":
  test "getProducer returns Unbound":
    var q: BQueue[int, ccMulti, ccMulti, 1024, 8, 8]
    let u: Unbound[int, AnyThreadTag, BQueue[int, ccMulti, ccMulti, 1024, 8, 8]] =
      q.getProducer()
    check u.idx >= 0

  test "getConsumer returns Unbound":
    var q: BQueue[int, ccMulti, ccMulti, 1024, 8, 8]
    let u: Unbound[int, AnyThreadTag, BQueue[int, ccMulti, ccMulti, 1024, 8, 8]] =
      q.getConsumer()
    check u.idx >= 0
