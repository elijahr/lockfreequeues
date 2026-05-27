import options
import unittest2

import lockfreequeues
import ./t_integration
import ./t_mup
import ./t_sic

var queue = newMpscQueue[int, 8, 4]()

suite "Mpsc[N, P, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "producerCount":
    check(queue.producerCount == 4)

  test "initial state":
    queue.checkState(head = 0'u64, tail = 0'u64)

suite "getProducer(Mpsc[N, P, T])":
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

suite "push(Mpsc[N, P, T])":
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

suite "pop(Mpsc[N, P, T])":
  setup:
    queue.reset()

  test "one":
    testSicPopOne(queue)

  test "all":
    testSicPopAll(queue)

  test "empty":
    testSicPopEmpty(queue)

  test "too many":
    testSicPopTooMany(queue)

  test "wrap":
    testSicPopWrap(queue)

suite "pop(Mpsc[N, P, T], int)":
  setup:
    queue.reset()

  test "one":
    testSicPopCountOne(queue)

  test "all":
    testSicPopCountAll(queue)

  test "empty":
    testSicPopCountEmpty(queue)

  test "too many":
    testSicPopCountTooMany(queue)

  test "wrap":
    testSicPopCountWrap(queue)

suite "capacity(Mpsc[N, P, T])":
  test "basic":
    testCapacity(queue)

suite "Mpsc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)
