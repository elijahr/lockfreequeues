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
import ./t_sic


var queue: Mupsic[8, 4, int]


proc reset[N, P: static int, T](
  self: var Mupsic[N, P, T]
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
  self: var Mupsic[N, P, T],
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


suite "Mupsic[N, P, T]":

  test "initial state":
    check(queue.state == (
      head: 0,
      tail: 0,
      prevPid: 0,
      storage: repeat(0, 8),
      producers: repeat(initialProducer, 4)
    ))


suite "push(Mupsic, T)":

  setup:
    queue.reset()

  test "basic":
    check(queue.push(0, 1) == true)
    check(queue.push(0, 2) == true)
    check(queue.state == (
      head: 0,
      tail: 2,
      prevPid: 0,
      storage: @[1, 2, 0, 0, 0, 0, 0, 0],
      producers: @[
        Producer(tail: 2, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
    check(queue.push(1, 3) == true)
    check(queue.push(1, 4) == true)
    check(queue.state == (
      head: 0,
      tail: 4,
      prevPid: 1,
      storage: @[1, 2, 3, 4, 0, 0, 0, 0],
      producers: @[
        Producer(tail: 2, state: Synchronized, prevPid: 0),
        Producer(tail: 4, state: Synchronized, prevPid: 1),
        initialProducer,
        initialProducer,
      ]
    ))
    check(queue.push(2, 5) == true)
    check(queue.push(2, 6) == true)
    check(queue.state == (
      head: 0,
      tail: 6,
      prevPid: 2,
      storage: @[1, 2, 3, 4, 5, 6, 0, 0],
      producers: @[
        Producer(tail: 2, state: Synchronized, prevPid: 0),
        Producer(tail: 4, state: Synchronized, prevPid: 1),
        Producer(tail: 6, state: Synchronized, prevPid: 2),
        initialProducer,
      ]
    ))
    check(queue.push(3, 7) == true)
    check(queue.push(3, 8) == true)
    check(queue.state == (
      head: 0,
      tail: 8,
      prevPid: 3,
      storage: @[1, 2, 3, 4, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 2, state: Synchronized, prevPid: 0),
        Producer(tail: 4, state: Synchronized, prevPid: 1),
        Producer(tail: 6, state: Synchronized, prevPid: 2),
        Producer(tail: 8, state: Synchronized, prevPid: 3),
      ]
    ))


  test "overflow":
    for i in 1..8:
      discard queue.push(0, i)
    check(queue.push(0, 9) == false)
    check(queue.state == (
      head: 0,
      tail: 8,
      prevPid: 0,
      storage: @[1, 2, 3, 4, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 8, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ]
    ))

  test "wrap":
    for i in 1..4:
      discard queue.push(0, i)
    for i in 1..2:
      discard queue.pop()
    for i in 5..10:
      check(queue.push(0, i) == true)
    check(queue.state == (
      head: 2,
      tail: 10,
      prevPid: 0,
      storage: @[9, 10, 3, 4, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 10, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ]
    ))


suite "push(Mupsic, seq)":

  setup:
    queue.reset()

  test "basic":
    check(queue.push(0, @[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
    check(queue.state == (
      head: 0,
      tail: 8,
      prevPid: 0,
      storage: @[1, 2, 3, 4, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 8, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ]
    ))

  test "overflow":
    let res = queue.push(
      0,
      @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    )
    check(res.isSome)
    check(res.get() == @[9, 10, 11, 12, 13, 14, 15, 16])
    check(queue.state == (
      head: 0,
      tail: 8,
      prevPid: 0,
      storage: @[1, 2, 3, 4, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 8, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ]
    ))

  test "wrap":
    discard queue.push(0, @[1, 2, 3, 4])
    for i in 1..2:
      discard queue.pop()
    var res = queue.push(0, @[5, 6, 7, 8, 9, 10])
    check(res.isNone)
    check(queue.state == (
      head: 2,
      tail: 10,
      prevPid: 0,
      storage: @[9, 10, 3, 4, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 10, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ]
    ))


suite "pop(Mupsic)":

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


suite "pop(Mupsic, int)":

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


suite "capacity(Mupsic)":

  test "basic":
    testCapacity(queue)


suite "Mupsic integration":

  setup:
    queue.reset()

  test "head and tail reset":
    testHeadAndTailReset(queue)

  test "wraps":
    testWraps(queue)

