# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import sequtils
import sugar
import unittest

import lockfreequeues
import lockfreequeues/producer
import ./t_integration
import ./t_mup
import ./t_sic


var queue = initMupsicQueue[8, 4, int]()


proc reset[N, P: static int, T](
  self: var MupsicStaticQueue[N, P, T]
) {.inline.} =
  ## Resets the queue to its default state.
  ## Should only be used in single-threaded unit tests.
  self.head.release(0)
  self.tail.release(0)
  self.prevPid.release(0)
  for n in 0..<N:
    self.storage[n].reset()
  for p in 0..<P:
    self.producers[p].reset()


proc state[N, P: static int, T](
  self: var MupsicStaticQueue[N, P, T],
): tuple[
    head: int,
    tail: int,
    prevPid: int,
    storage: seq[T],
    producers: seq[Producer],
  ] =
  ## Retrieve current state of the queue
  ## Should only be used in single-threaded unit tests,
  ## as data may be torn.
  let producers = collect(newSeq):
    for i in self.producers:
      var item = i
      item.acquire
  return (
    head: self.head.acquire.int,
    tail: self.tail.acquire.int,
    prevPid: self.prevPid.acquire.int,
    storage: self.storage[0..^1],
    producers: producers
  )


suite "initMupsicQueue[N, P, T]()":

  test "N == 0 raises ValueError":
    expect(ValueError):
      discard initMupsicQueue[0, 1, int]()

  test "P == 0 raises ValueError":
    expect(ValueError):
      discard initMupsicQueue[1, 0, int]()

  test "basic":
    check(queue.state == (
      head: 0,
      tail: 0,
      prevPid: 0,
      storage: repeat(0, 8),
      producers: repeat(initialProducer, 4)
    ))


suite "push(MupsicStaticQueue[N, T], T)":

  setup:
    queue.reset()

  test "basic":
    testMupPush(queue)

  test "overflow":
    testMupPushOverflow(queue)

  test "wrap":
    testMupPushWrap(queue)


suite "push(MupsicStaticQueue[N, T], seq[T])":

  setup:
    queue.reset()

  test "basic":
    testMupPushSeq(queue)

  test "overflow":
    testMupPushSeqOverflow(queue)

  test "wrap":
    testMupPushSeqWrap(queue)


suite "pop(MupsicStaticQueue[N, T])":

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


suite "pop(MupsicStaticQueue[N, T], int)":

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


suite "capacity(MupsicStaticQueue[N, T])":

  test "basic":
    testCapacity(queue)


suite "MupsicStaticQueue[N, T] integration":

  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)

