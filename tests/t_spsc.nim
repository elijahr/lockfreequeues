import options
import sequtils
import unittest2

import lockfreequeues
import ./t_integration
import ./t_sic
import ./t_sip

var queue = newSpscQueue[int, 8]()

suite "Spsc[N, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "initial state":
    queue.checkState(
      head = 0, tail = 0, storage = repeat(0, 9) # N+1 slots
    )

suite "push(Spsc[N, T], T)":
  setup:
    queue.reset()

  test "basic":
    testSipPush(queue)

  test "overflow":
    testSipPushOverflow(queue)

  test "wrap":
    testSipPushWrap(queue)

suite "push(Spsc[N, T], seq[T])":
  setup:
    queue.reset()

  test "basic":
    testSipPushSeq(queue)

  test "overflow":
    testSipPushSeqOverflow(queue)

  test "wrap":
    testSipPushSeqWrap(queue)

suite "pop(Spsc)":
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

suite "pop(Spsc, int)":
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

suite "capacity(Spsc)":
  test "basic":
    testCapacity(queue)

suite "Spsc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)
