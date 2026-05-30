import debra/atomics
import debra/atomics/dsl
import options
import sequtils
import unittest2

import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import ./t_integration
import ./t_muc
import ./t_mup

var queue = newMpmcQueue[int, 8, 4, 4]()

suite "Mpmc[N, P, C, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "producerCount":
    check(queue.producerCount == 4)

  test "initial state":
    queue.checkState(head = 0'u64, tail = 0'u64, data = repeat(0, 8))

suite "getProducer(Mpmc[N, P, C, T])":
  setup:
    queue.reset()

  test "assigns by thread id":
    testMupGetProducerAssigns(queue)

  test "reuses assigned":
    testMupGetProducerReusesAssigned(queue)

  test "explicit index":
    testMupGetProducerExplicitIndex(queue)

  test "throws NoProducersAvailableError":
    testMupGetProducerThrowsNoProducersAvailable(queue)

suite "push(Mpmc[N, P, C, T])":
  setup:
    queue.reset()

  # B.2 direct push on a ccMulti Queue is now a compile-time
  # `{.error.}`. The former runtime `InvalidCallDefect` smoke-tests are
  # superseded by compile-fail negative-controls under
  # tests/should_fail/.

suite "push(Producer[N, P, T], T)":
  setup:
    queue.reset()

  test "basic":
    testMupPush(queue)

  test "overflow":
    testMupPushOverflow(queue)

  test "wrap":
    testMupPushWrap(queue)

suite "push(Producer[N, P, T], seq[T])":
  setup:
    queue.reset()

  test "basic":
    testMupPushSeq(queue)

  test "overflow":
    testMupPushSeqOverflow(queue)

  test "wrap":
    testMupPushSeqWrap(queue)

suite "pop(Mpmc[N, P, C, T])":
  setup:
    queue.reset()

  test "one":
    testMucPopOne(queue)

  test "all":
    testMucPopAll(queue)

  test "empty":
    testMucPopEmpty(queue)

  test "too many":
    testMucPopTooMany(queue)

  test "wrap":
    testMucPopWrap(queue)

suite "pop(Mpmc[N, P, C, T], int)":
  setup:
    queue.reset()

  test "one":
    testMucPopCountOne(queue)

  test "all":
    testMucPopCountAll(queue)

  test "empty":
    testMucPopCountEmpty(queue)

  test "too many":
    testMucPopCountTooMany(queue)

  test "wrap":
    testMucPopCountWrap(queue)

suite "capacity(Mpmc[N, P, C, T])":
  test "basic":
    testCapacity(queue)

suite "Mpmc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    check(queue.getProducerHere(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

    var popRes = queue.getConsumerHere(0).pop(4)

    check(popRes.isSome)
    check(popRes.get == @[1, 2, 3, 4])

    var pushRes = queue.getProducerHere(0).push(@[9, 10, 11, 12])

    check(pushRes.isNone)

    queue.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

    popRes = queue.getConsumerHere(0).pop(4)
    check(popRes.isSome)
    check(popRes.get == @[5, 6, 7, 8])

    queue.checkState(head = 8'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

    popRes = queue.getConsumerHere(1).pop(4)
    check(popRes.isSome)
    check(popRes.get == @[9, 10, 11, 12])

    queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))
