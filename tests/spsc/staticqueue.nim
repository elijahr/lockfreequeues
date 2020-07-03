# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import os
import unittest

import lockfreequeues/spsc/queueinterface
import lockfreequeues/spsc/staticqueue
import ./queuetests


var queue = newSPSCQueue[8, int]()


proc reset[N: static int, T](
  self: var StaticQueue[N, T]
) {.inline.} =
  ## Resets the queue to its default state.
  ## Should only be used in single-threaded unit tests.
  self.face.move(0, 0, N)
  for i in 0..<N:
    self.storage[i].reset()


proc move[N: static int, T](
  self: var StaticQueue[N, T],
  head: int,
  tail: int,
) {.inline.} =
  ## Move the queue's `head` and `tail`.
  ## Should only be used in single-threaded unit tests.
  self.face.move(head, tail, N)


proc state[N: static int, T](
  self: var StaticQueue[N, T],
): tuple[
    head: int,
    tail: int,
    storage: seq[T],
  ] =
  ## Retrieve current state of the queue
  ## Should only be used in single-threaded unit tests,
  ## as data may be torn.
  return (
    head: self.face.head.load(moRelaxed),
    tail: self.face.tail.load(moRelaxed),
    storage: self.storage[0..^1],
  )


suite "newSPSCQueue[N, T]()":

  test "N <= 0 raises ValueError":
    expect(ValueError):
      discard newSPSCQueue[-1, int]()
    expect(ValueError):
      discard newSPSCQueue[0, int]()

  test "basic":
    require(queue.state == (
      head: 0,
      tail: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 0]
    ))


suite "push(StaticQueue[N, T], T)":

  setup:
    queue.reset()

  test "basic":
    testPush(queue)

  test "overflow":
    testPushOverflow(queue)

  test "wrap":
    testPushWrap(queue)


suite "push(StaticQueue[N, T], seq[T])":

  setup:
    queue.reset()

  test "basic":
    testPushSeq(queue)

  test "overflow":
    testPushSeqOverflow(queue)

  test "wrap":
    testPushSeqWrap(queue)


suite "pop(StaticQueue[N, T])":

  setup:
    queue.reset()

  test "one":
    testPopOne(queue)

  test "all":
    testPopAll(queue)

  test "empty":
    testPopEmpty(queue)

  test "too many":
    testPopTooMany(queue)

  test "wrap":
    testPopWrap(queue)


suite "pop(StaticQueue[N, T], int)":

  setup:
    queue.reset()

  test "one":
    testPopCountOne(queue)

  test "all":
    testPopCountAll(queue)

  test "empty":
    testPopCountEmpty(queue)

  test "too many":
    testPopCountTooMany(queue)

  test "wrap":
    testPopCountWrap(queue)


suite "capacity(StaticQueue[N, T])":

  test "basic":
    testCapacity(queue)


suite "StaticQueue[N, T] integration":

  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)

