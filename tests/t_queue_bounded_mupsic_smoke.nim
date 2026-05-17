## TDD smoke test for v5.0.0 Track B1 — Queue rkNone bounded body.
##
## Exercises the mupsic-equivalent shape (`ccMulti × ccSingle`) only.
## The full per-cardinality migration tests land in Track B2.
##
## Impl plan §B1 Step 1. Doc C §3.0 (bounded body), §5 (initQueue), §6.1.

import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

suite "bounded mupsic-equiv push/pop smoke":
  test "push then pop returns the same value":
    var q = initQueue[int, ccMulti, ccSingle, stEager, 16, 4, 0]()
    let producer = q.getProducer(0)
    check producer.push(42)
    let r = q.pop()
    check r.isSome
    check r.get == 42

  test "push fills, push-overfull returns false":
    var q = initQueue[int, ccMulti, ccSingle, stEager, 4, 4, 0]()
    let producer = q.getProducer(0)
    for i in 0 ..< 4: check producer.push(i)
    check not producer.push(99)  # full

  test "pop on empty returns none":
    var q = initQueue[int, ccMulti, ccSingle, stEager, 16, 4, 0]()
    check q.pop().isNone
