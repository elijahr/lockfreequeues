## Migrated from `t_mupmuc.nim` — exercises the unified Queue type
## under the `ccMulti x ccMulti` (MPMC) bounded cardinality, which
## corresponds to the legacy `Mupmuc[N, P, C, T]` shape.
##
## Mechanical conversion per Doc C 5 (migration table):
##   Mupmuc[N, P, C, T] -> BQueue[T, ccMulti, ccMulti, ##                                N, P, C]
##   initMupmuc[N, P, C, T]() -> newBQueue[T, ccMulti, ccMulti, ##                                          N, P, C]()
##
## Test count parity: 28 tests (matches t_mupmuc.nim).
## Track B / Task B2. Doc C 3.7, 5, 6.1.

import lockfreequeues/atomic_dsl
import options
import sequtils
import unittest2

import lockfreequeues
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import ./t_integration
import ./t_muc
import ./t_mup

var q = q_mod.newBQueue[int, ccMulti, ccMulti, 8, 4, 4]()

suite "BQueue[int, ccMulti, ccMulti, 8, 4, 4]":
  test "capacity":
    check(q.capacity == 8)

  test "producerCount":
    check(q.producerCount == 4)

  test "initial state":
    q.checkState(head = 0'u64, tail = 0'u64, data = repeat(0, 8))

suite "getProducer(Queue MPMC)":
  setup:
    q.reset()

  test "assigns by thread id":
    testMupGetProducerAssigns(q)

  test "reuses assigned":
    testMupGetProducerReusesAssigned(q)

  test "explicit index":
    testMupGetProducerExplicitIndex(q)

  test "throws NoProducersAvailableError":
    testMupGetProducerThrowsNoProducersAvailable(q)

suite "push(Queue MPMC)":
  setup:
    q.reset()

  # B.2 Bundle E: direct push on a ccMulti Queue is now a compile-time
  # `{.error.}`. The former runtime `InvalidCallDefect` smoke-tests are
  # superseded by Bundle J compile-fail negative-controls under
  # tests/should_fail/ (added in 3.3.11-B.3).

suite "push(QueueProducer MPMC, T)":
  setup:
    q.reset()

  test "basic":
    testMupPush(q)

  test "overflow":
    testMupPushOverflow(q)

  test "wrap":
    testMupPushWrap(q)

suite "push(QueueProducer MPMC, seq[T])":
  setup:
    q.reset()

  test "basic":
    testMupPushSeq(q)

  test "overflow":
    testMupPushSeqOverflow(q)

  test "wrap":
    testMupPushSeqWrap(q)

suite "pop(Queue MPMC)":
  setup:
    q.reset()

  test "one":
    testMucPopOne(q)

  test "all":
    testMucPopAll(q)

  test "empty":
    testMucPopEmpty(q)

  test "too many":
    testMucPopTooMany(q)

  test "wrap":
    testMucPopWrap(q)

suite "pop(Queue MPMC, int)":
  setup:
    q.reset()

  test "one":
    testMucPopCountOne(q)

  test "all":
    testMucPopCountAll(q)

  test "empty":
    testMucPopCountEmpty(q)

  test "too many":
    testMucPopCountTooMany(q)

  test "wrap":
    testMucPopCountWrap(q)

suite "capacity(Queue MPMC)":
  test "basic":
    testCapacity(q)

suite "Queue MPMC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

  test "wraps":
    check(q.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

    var popRes = q.getConsumer(0).pop(4)

    check(popRes.isSome)
    check(popRes.get == @[1, 2, 3, 4])

    let pushRes = q.getProducer(0).push(@[9, 10, 11, 12])

    check(pushRes.isNone)

    q.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

    popRes = q.getConsumer(0).pop(4)
    check(popRes.isSome)
    check(popRes.get == @[5, 6, 7, 8])

    q.checkState(head = 8'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

    popRes = q.getConsumer(1).pop(4)
    check(popRes.isSome)
    check(popRes.get == @[9, 10, 11, 12])

    q.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))
