import lockfreequeues/atomic_dsl
import options
import sequtils
import unittest2

import lockfreequeues
import lockfreequeues/exceptions
import lockfreequeues/mupsic
import lockfreequeues/sipmuc
import ./t_integration
import ./t_suc

var queue = initSipmuc[8, 4, int]()

suite "Sipmuc[N, C, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "consumerCount":
    check(queue.consumerCount == 4)

  test "initial state":
    queue.checkState(head = 0, tail = 0, storage = repeat(0, 8))
    queue.checkState(head = 0, reservedHead = 0, tail = 0)

suite "getConsumer(Sipmuc[N, C, T])":
  setup:
    queue.reset()

  test "assigns by thread id":
    testSucGetConsumerAssigns(queue)

  test "reuses assigned":
    testSucGetConsumerReusesAssigned(queue)

  test "explicit index":
    testSucGetConsumerExplicitIndex(queue)

  test "throws NoConsumersAvailableError":
    # Fill all consumer slots with fake thread IDs
    for c in 0 ..< 4:
      queue.consumerThreadIds[c].store(c + 1000, moSequentiallyConsistent)

    expect sipmuc.NoConsumersAvailableError:
      discard queue.getConsumer()

suite "pop(Consumer[N, C, T])":
  setup:
    queue.reset()

  test "one":
    testSucPopOne(queue)

  test "all":
    testSucPopAll(queue)

  test "empty":
    testSucPopEmpty(queue)

  test "too many":
    testSucPopTooMany(queue)

  test "wrap":
    testSucPopWrap(queue)

suite "pop(Consumer[N, C, T], int)":
  setup:
    queue.reset()

  test "one":
    testSucPopCountOne(queue)

  test "all":
    testSucPopCountAll(queue)

  test "empty":
    testSucPopCountEmpty(queue)

  test "too many":
    testSucPopCountTooMany(queue)

  test "wrap":
    testSucPopCountWrap(queue)

suite "pop(Sipmuc[N, C, T])":
  setup:
    queue.reset()

  test "single should fail":
    expect InvalidCallDefect:
      discard queue.pop()

  test "batch should fail":
    expect InvalidCallDefect:
      discard queue.pop(1)

suite "push(Sipmuc[N, C, T], T)":
  setup:
    queue.reset()

  test "basic":
    # Sipmuc uses Sipsic's push directly (single producer)
    check(queue.push(1) == true)
    queue.checkState(head = 0, tail = 1, storage = (@[1, 0, 0, 0, 0, 0, 0, 0]))

  test "overflow":
    for i in 1 .. 8:
      check(queue.push(i) == true)
    check(queue.push(9) == false)

  test "wrap":
    for i in 1 .. 8:
      discard queue.push(i)
    for i in 1 .. 4:
      discard queue.getConsumer(0).pop()
    for i in 9 .. 12:
      check(queue.push(i) == true)
    queue.checkState(head = 4, tail = 12, storage = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "push(Sipmuc[N, C, T], seq[T])":
  setup:
    queue.reset()

  test "basic":
    check(queue.push(@[1, 2, 3, 4]).isNone)
    queue.checkState(head = 0, tail = 4, storage = (@[1, 2, 3, 4, 0, 0, 0, 0]))

  test "overflow":
    let unpushed = queue.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    check(unpushed.isSome)
    check(unpushed.get == 8 .. 9)

  test "wrap":
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    for i in 1 .. 4:
      discard queue.getConsumer(0).pop()
    check(queue.push(@[9, 10, 11, 12]).isNone)
    queue.checkState(head = 4, tail = 12, storage = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "capacity(Sipmuc[N, C, T])":
  test "basic":
    testCapacity(queue)

suite "Sipmuc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)
