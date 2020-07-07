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
import lockfreequeues/spsc/sharedqueue
import ./queuetests


var queue = newSPSCQueue[int](8)


proc reset[T](
  self: var SharedQueue[T]
) {.inline.} =
  ## Resets the queue to its default state.
  ## Should only be used in single-threaded unit tests.
  self.face[].move(0, 0, self.capacity)
  for i in 0..<self.capacity:
    self.storage[i].reset()


proc move[T](
  self: var SharedQueue[T],
  head: int,
  tail: int,
) {.inline.} =
  ## Move the queue's `head` and `tail`.
  ## Should only be used in single-threaded unit tests.
  self.face[].move(head, tail, self.capacity)


proc state[T](
  self: var SharedQueue[T],
): tuple[
    head: int,
    tail: int,
    storage: seq[T],
  ] =
  ## Retrieve current state of the queue
  ## Should only be used in single-threaded unit tests,
  ## as data may be torn.
  var storage = newSeq[T](self.capacity)
  for i in 0..<self.capacity:
    storage[i] = self.storage[i]
  return (
    head: self.face[].head.load(moRelaxed),
    tail: self.face[].tail.load(moRelaxed),
    storage: storage,
  )


suite "newSPSCQueue[T](n)":

  test "n <= 0 raises ValueError":
    expect(ValueError):
      discard newSPSCQueue[int](-1)
    expect(ValueError):
      discard newSPSCQueue[int](0)

  test "basic":
    require(queue.state == (
      head: 0,
      tail: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 0]
    ))


suite "push(SharedQueue[T], T)":

  setup:
    queue.reset()

  test "basic":
    testPush(queue)

  test "overflow":
    testPushOverflow(queue)

  test "wrap":
    testPushWrap(queue)


suite "push(SharedQueue[T], seq[T])":

  setup:
    queue.reset()

  test "basic":
    testPushSeq(queue)

  test "overflow":
    testPushSeqOverflow(queue)

  test "wrap":
    testPushSeqWrap(queue)


suite "pop(SharedQueue[T])":

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


suite "pop(SharedQueue[T], int)":

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


suite "SharedQueue[T].capacity":

  test "basic":
    testCapacity(queue)


suite "SharedQueue[T] integration":

  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)

