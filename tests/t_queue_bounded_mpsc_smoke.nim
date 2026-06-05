## TDD smoke test for v5.0.0 Queue rkNone bounded body.
##
## Exercises the mpsc-equivalent shape (`ccMulti × ccSingle`) only.
## The full per-cardinality migration tests live in the
## `t_queue_bounded_*` files alongside this one.

import options
import unittest2

import lockfreequeues/bqueue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "bounded mpsc-equiv push/pop smoke":
  test "push then pop returns the same value":
    var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
    var producer = q.getProducerHere(0)
    check producer.push(42)
    let r = q.pop()
    check r.isSome
    check r.get == 42

  test "push fills, push-overfull returns false":
    var q = newBQueue[int, ccMulti, ccSingle, 4, 4, 0]()
    var producer = q.getProducerHere(0)
    for i in 0 ..< 4:
      check producer.push(i)
    check not producer.push(99) # full

  test "pop on empty returns none":
    var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
    check q.pop().isNone
