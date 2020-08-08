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
import ./t_muc
import ./t_mup


when (NimMajor, NimMinor) < (1, 3):
  type IndexDefect = IndexError
  type AssertionDefect = AssertionError


var queue = initMupmuc[8, 4, 4, int]()


suite "Mupmuc[N, P, C, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "producerCount":
    check(queue.producerCount == 4)

  test "initial state":
    queue.checkState(
      head=0,
      tail=0,
      storage=repeat(0, 8),
    )
    queue.checkState(
      prevProducerIdx=NoProducerIdx,
      producerTails=repeat(0, 4),
    )


suite "getProducer(Mupmuc[N, P, C, T])":
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


suite "push(Mupmuc[N, P, C, T])":
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


suite "pop(Mupmuc[N, P, C, T])":
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


suite "pop(Mupmuc[N, P, C, T], int)":
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


suite "capacity(Mupmuc[N, P, C, T])":
  test "basic":
    testCapacity(queue)


suite "Mupmuc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    when ((queue is Mupsic) or (queue is Mupmuc)):
      check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
    else:
      check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

    var popRes =
      when queue is Mupmuc:
        queue.getConsumer(0).pop(4)
      else:
        queue.pop(4)

    check(popRes.isSome)
    check(popRes.get == @[1, 2, 3, 4])

    let pushRes =
      when ((queue is Mupsic) or (queue is Mupmuc)):
        queue.getProducer(0).push(@[9, 10, 11, 12])
      else:
        queue.push(@[9, 10, 11, 12])

    check(pushRes.isNone)

    queue.checkState(
      head=4,
      tail=12,
      storage=(@[9, 10, 11, 12, 5, 6, 7, 8]),
    )
    when ((queue is Mupsic) or (queue is Mupmuc)):
      queue.checkState(
        prevProducerIdx=0,
        producerTails=(@[12, 0, 0, 0]),
      )

    when queue is Mupmuc:
      queue.checkState(
        prevConsumerIdx=0,
        consumerHeads=(@[4, 0, 0, 0]),
      )

    popRes =
      when queue is Mupmuc:
        queue.getConsumer(0).pop(4)
      else:
        queue.pop(4)
    check(popRes.isSome)
    check(popRes.get == @[5, 6, 7, 8])

    queue.checkState(
      head=8,
      tail=12,
      storage=(@[9, 10, 11, 12, 5, 6, 7, 8]),
    )

    when ((queue is Mupsic) or (queue is Mupmuc)):
      queue.checkState(
        prevProducerIdx=0,
        producerTails=(@[12, 0, 0, 0]),
      )

    when queue is Mupmuc:
      queue.checkState(
        prevConsumerIdx=0,
        consumerHeads=(@[8, 0, 0, 0]),
      )

    popRes =
      when queue is Mupmuc:
        queue.getConsumer(1).pop(4)
      else:
        queue.pop(4)
    check(popRes.isSome)
    check(popRes.get == @[9, 10, 11, 12])

    queue.checkState(
      head=12,
      tail=12,
      storage=(@[9, 10, 11, 12, 5, 6, 7, 8]),
    )
    when ((queue is Mupsic) or (queue is Mupmuc)):
      queue.checkState(
        prevProducerIdx=0,
        producerTails=(@[12, 0, 0, 0]),
      )
    when queue is Mupmuc:
      queue.checkState(
        prevConsumerIdx=1,
        consumerHeads=(@[8, 12, 0, 0]),
      )


