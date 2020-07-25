# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import sequtils
import unittest

import lockfreequeues
import ./t_integration
import ./t_sic
import ./t_sip


var queue = initSipsicQueue[8, int]()


proc reset[N: static int, T](
  self: var SipsicStaticQueue[N, T]
) {.inline.} =
  ## Resets the queue to its default state.
  ## Should only be used in single-threaded unit tests.
  self.head.release(0)
  self.tail.release(0)
  for i in 0..<N:
    self.storage[i].reset()


proc state[N: static int, T](
  self: var SipsicStaticQueue[N, T],
): tuple[
    head: int,
    tail: int,
    storage: seq[T],
  ] =
  ## Retrieve current state of the queue
  ## Should only be used in single-threaded unit tests,
  ## as data may be torn.
  return (
    head: self.head.acquire,
    tail: self.tail.acquire,
    storage: self.storage[0..^1],
  )


suite "initSipsicQueue[N, T]()":

  test "N == 0 raises ValueError":
    expect(ValueError):
      discard initSipsicQueue[0, int]()

  test "basic":
    require(queue.state == (
      head: 0,
      tail: 0,
      storage: repeat(0, 8)
    ))


suite "push(SipsicStaticQueue[N, T], T)":

  setup:
    queue.reset()

  test "basic":
    testSipPush(queue)

  test "overflow":
    testSipPushOverflow(queue)

  test "wrap":
    testSipPushWrap(queue)


suite "push(SipsicStaticQueue[N, T], seq[T])":

  setup:
    queue.reset()

  test "basic":
    testSipPushSeq(queue)

  test "overflow":
    testSipPushSeqOverflow(queue)

  test "wrap":
    testSipPushSeqWrap(queue)


suite "pop(SipsicStaticQueue[N, T])":

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


suite "pop(SipsicStaticQueue[N, T], int)":

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


suite "capacity(SipsicStaticQueue[N, T])":

  test "basic":
    testCapacity(queue)


suite "SipsicStaticQueue[N, T] integration":

  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)

