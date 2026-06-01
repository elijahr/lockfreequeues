import std/unittest
import lockfreequeues/queue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "queue endpoint compile":
  test "getProducer returns Unbound (SPSC)":
    var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
    let u: Unbound[int, AnyThreadTag, typeof(q)] = q.getProducer()
    check u.idx == -1 # SPSC: no meaningful slot

  test "getConsumer returns Unbound (SPSC)":
    var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
    let u: Unbound[int, AnyThreadTag, typeof(q)] = q.getConsumer()
    check u.idx == -1

  test "getProducer returns Unbound (MPSC, slot reserved)":
    var q = newUnboundedMpscQueue[int, stEager, 16, 4]()
    let u: Unbound[int, AnyThreadTag, typeof(q)] = q.getProducer()
    check u.idx >= 0 # MPSC: ccMulti producer reserved a slot
