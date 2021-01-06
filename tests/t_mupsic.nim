# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import options
import sequtils
import unittest

import lockfreequeues
import ./t_integration
import ./t_mup
import ./t_sic


var queue = initMupsic[8, 4, int]()


suite "Mupsic[N, P, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "producerCount":
    check(queue.producerCount == 4)

  test "initial state":
    queue.checkState(
      head = 0,
      tail = 0,
      storage = repeat(0, 8),
    )
    queue.checkState(
      prevProducerIdx = NoProducerIdx,
      producerTails = repeat(0, 4),
    )


suite "getProducer(Mupsic[N, P, T])":
  setup:
    queue.reset()

  test "assigns by thread id":
    testMupGetProducerAssigns(queue)

  test "reuses assigned":
    testMupGetProducerReusesAssigned(queue)

  test "explicit index":
    testMupGetProducerExplicitIndex(queue)

  test "throws NoProducersAvailableDefect":
    testMupGetProducerThrowsNoProducersAvailable(queue)


suite "push(Mupsic[N, P, T])":
  setup:
    queue.reset()

  test "seq[T] should fail":
    expect InvalidCallDefect:
      discard queue.push(1)

  test "T should fail":
    expect InvalidCallDefect:
      discard queue.push(@[1])


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


suite "pop(Mupsic[N, P, T])":
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


suite "pop(Mupsic[N, P, T], int)":
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


suite "capacity(Mupsic[N, P, T])":
  test "basic":
    testCapacity(queue)


suite "Mupsic integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)

