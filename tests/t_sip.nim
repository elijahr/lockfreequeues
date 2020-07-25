# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest


template testSipPush*(queue: untyped) =
  for i in 1..8:
    check(queue.push(i) == true)
  check(queue.state == (
    head: 0,
    tail: 8,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testSipPushOverflow*(queue: untyped) =
  for i in 1..8:
    discard queue.push(i)
  check(queue.push(9) == false)
  check(queue.state == (
    head: 0,
    tail: 8,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testSipPushWrap*(queue: untyped) =
  for i in 1..4:
    discard queue.push(i)
  for i in 1..2:
    discard queue.pop()
  for i in 5..10:
    check(queue.push(i) == true)
  check(queue.state == (
    head: 2,
    tail: 10,
    storage: @[9, 10, 3, 4, 5, 6, 7, 8]
  ))


template testSipPushSeq*(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  check(queue.state == (
    head: 0,
    tail: 8,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testSipPushSeqOverflow*(queue: untyped) =
  let res = queue.push(
    @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  )
  check(res.isSome)
  check(res.get() == @[9, 10, 11, 12, 13, 14, 15, 16])
  check(queue.state == (
    head: 0,
    tail: 8,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testSipPushSeqWrap*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4])
  for i in 1..2:
    discard queue.pop()
  var res = queue.push(@[5, 6, 7, 8, 9, 10])
  check(res.isNone)
  check(queue.state == (
    head: 2,
    tail: 10,
    storage: @[9, 10, 3, 4, 5, 6, 7, 8]
  ))
