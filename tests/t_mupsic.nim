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


when (NimMajor, NimMinor) < (1, 3):
  type IndexDefect = IndexError


var queue = initMupsic[8, 4, int]()


suite "Mupsic[N, P, T]":

  test "capacity":
    check(queue.capacity == 8)

  test "producerCount":
    check(queue.producerCount == 4)

  test "initial state":
    check(queue.state == (
      head: 0,
      tail: 0,
      prevPid: -1,
      storage: repeat(0, 8),
      producers: repeat(0, 4)
    ))


suite "push(Mupsic[N, P, T], int, T)":

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
        2,
        0,
        0,
        0,
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
        2,
        4,
        0,
        0,
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
        2,
        4,
        6,
        0,
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
        2,
        4,
        6,
        8,
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
        8,
        0,
        0,
        0,
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
        10,
        0,
        0,
        0,
      ]
    ))

  test "invalid pid":
    expect IndexDefect:
      discard queue.push(9, 1)


suite "push(Mupsic[N, P, T], int, seq[T])":

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
        8,
        0,
        0,
        0,
      ]
    ))

  test "overflow":
    let res = queue.push(
      0,
      @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    )
    check(res.isSome)
    check(res.get == 8..15)
    check(queue.state == (
      head: 0,
      tail: 8,
      prevPid: 0,
      storage: @[1, 2, 3, 4, 5, 6, 7, 8],
      producers: @[
        8,
        0,
        0,
        0,
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
        10,
        0,
        0,
        0,
      ]
    ))

  test "invalid pid":
    expect IndexDefect:
      discard queue.push(9, @[1])


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

