import std/[unittest, options]
import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "bqueue push/pop on Bound":
  test "MPSC: push goes through Bound[Producer] and pop through Bound[Consumer]":
    var q: BQueue[int, ccMulti, ccSingle, 64, 4, 0]
    var bp = q.getProducer().bindToThread()
    check bp.push(42)

  test "MPMC: push and pop on Bound endpoints":
    var q: BQueue[int, ccMulti, ccMulti, 64, 4, 4]
    var bp = q.getProducer().bindToThread()
    check bp.push(7)
    var bc = q.getConsumer().bindToThread()
    let got = bc.pop()
    check got.isSome and got.get == 7
