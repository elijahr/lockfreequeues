import debra/atomics
import debra/atomics/dsl
import options
import sequtils
import unittest2

import lockfreequeues
import lockfreequeues/exceptions
import ./t_integration
import ./t_suc

var queue = newSpmcQueue[int, 8, 4]()

suite "Spmc[N, C, T]":
  test "capacity":
    check(queue.capacity == 8)

  test "consumerCount":
    check(queue.consumerCount == 4)

  test "initial state":
    queue.checkState(head = 0'u64, tail = 0'u64, data = repeat(0, 8))
    queue.checkState(head = 0'u64, tail = 0'u64)

suite "getConsumer(Spmc[N, C, T])":
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

    expect NoConsumersAvailableError:
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

suite "pop(Spmc[N, C, T])":
  setup:
    queue.reset()

  # B.2 direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. The former runtime `InvalidCallDefect`
  # smoke-tests are superseded by compile-fail negative-
  # controls under tests/should_fail/.

suite "push(Spmc[N, C, T], T)":
  setup:
    queue.reset()

  test "basic":
    # Spmc uses Spsc's push directly (single producer)
    check(queue.push(1) == true)
    # Only slot 0 is published (tail advanced to 1). Cell data outside the
    # published region is undefined per Vyukov canonical protocol — reset()
    # does not zero payload.data, so we cannot assert on un-pushed slots.
    queue.checkState(head = 0'u64, tail = 1'u64)

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
    queue.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "push(Spmc[N, C, T], seq[T])":
  setup:
    queue.reset()

  test "basic":
    check(queue.push(@[1, 2, 3, 4]).isNone)
    # Slots 0-3 are published (tail advanced to 4). Cell data outside the
    # published region is undefined per Vyukov canonical protocol — reset()
    # does not zero payload.data, so we cannot assert on un-pushed slots.
    queue.checkState(head = 0'u64, tail = 4'u64)

  test "overflow":
    let unpushed = queue.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    check(unpushed.isSome)
    check(unpushed.get == 8 .. 9)

  test "wrap":
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    for i in 1 .. 4:
      discard queue.getConsumer(0).pop()
    check(queue.push(@[9, 10, 11, 12]).isNone)
    queue.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "capacity(Spmc[N, C, T])":
  test "basic":
    testCapacity(queue)

suite "Spmc integration":
  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)
