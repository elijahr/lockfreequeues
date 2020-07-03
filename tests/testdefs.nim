# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Single-producer, single-consumer, lock-free queue implementations for Nim.
##
## Based on the algorithm outlined by Juho Snellman at
## https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/

import unittest


template testReset*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  queue.reset()
  require(queue.state == (
    head: 0u,
    tail: 0u,
    storage: @[0, 0, 0, 0, 0, 0, 0, 0]
  ))


template testPush*(queue: untyped) =
  for i in 1..8:
    check(queue.push(i) == true)
  check(queue.state == (
    head: 0u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPushOverflow*(queue: untyped) =
  for i in 1..8:
    discard queue.push(i)
  check(queue.push(9) == false)
  check(queue.state == (
    head: 0u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPushWrap*(queue: untyped) =
  for i in 1..4:
    discard queue.push(i)
  for i in 1..2:
    discard queue.pop()
  for i in 5..10:
    check(queue.push(i) == true)
  check(queue.state == (
    head: 2u,
    tail: 10u,
    storage: @[9, 10, 3, 4, 5, 6, 7, 8]
  ))


template testPushSeq*(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  check(queue.state == (
    head: 0u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPushSeqOverflow*(queue: untyped) =
  let res = queue.push(
    @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  )
  check(res.isSome)
  check(res.get() == @[9, 10, 11, 12, 13, 14, 15, 16])
  check(queue.state == (
    head: 0u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPushSeqWrap*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4])
  discard queue.pop(2)
  var res = queue.push(@[5, 6, 7, 8, 9, 10])
  check(res.isNone)
  check(queue.state == (
    head: 2u,
    tail: 10u,
    storage: @[9, 10, 3, 4, 5, 6, 7, 8]
  ))


template testPopOne*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let res = queue.pop()
  check(res.isSome)
  check(res.get() == 1)
  check(queue.state == (
    head: 1u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))

template testPopAll*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  var items = newSeq[int]()
  for i in 1..8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get())
  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])
  check(queue.state == (
    head: 8u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPopEmpty*(queue: untyped) =
  check(queue.pop().isNone)
  check(queue.state == (
    head: 0u,
    tail: 0u,
    storage: @[0, 0, 0, 0, 0, 0, 0, 0]
  ))


template testPopTooMany*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1..8:
    discard queue.pop()
  check(queue.pop().isNone)
  check(queue.state == (
    head: 8u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPopWrap*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1..4:
    discard queue.pop()
  discard queue.push(@[9, 10, 11, 12])
  var items = newSeq[int]()
  for i in 1..8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get())
  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])
  check(queue.state == (
    head: 12u,
    tail: 12u,
    storage: @[9, 10, 11, 12, 5, 6, 7, 8]
  ))


template testPopCountOne*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1..8:
    let popped = queue.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])
  check(queue.state == (
    head: 8u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPopCountAll*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  check(queue.state == (
    head: 8u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPopCountEmpty*(queue: untyped) =
  let popped = queue.pop(1)
  check(popped.isNone)
  check(queue.state == (
    head: 0u,
    tail: 0u,
    storage: @[0, 0, 0, 0, 0, 0, 0, 0]
  ))


template testPopCountTooMany*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  check(queue.state == (
    head: 8u,
    tail: 8u,
    storage: @[1, 2, 3, 4, 5, 6, 7, 8]
  ))


template testPopCountWrap*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  discard queue.pop(4)
  discard queue.push(@[9, 10, 11, 12])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])
  check(queue.state == (
    head: 12u,
    tail: 12u,
    storage: @[9, 10, 11, 12, 5, 6, 7, 8]
  ))


template testCapacity*(queue: untyped) =
  check(queue.capacity == 8)


template testResets*(queue: untyped) =
  queue.move(high(uint), high(uint))
  check(queue.state == (
    head: high(uint),
    tail: high(uint),
    storage: @[0, 0, 0, 0, 0, 0, 0, 0]
  ))
  check(queue.push(@[1]).isNone)
  check(queue.state == (
    head: high(uint),
    tail: 0'u,
    storage: @[0, 0, 0, 0, 0, 0, 0, 1]
  ))
  let res = queue.pop(1)
  check(res.isSome)
  check(res.get == @[1])
  check(queue.state == (
    head: 0u,
    tail: 0u,
    storage: @[0, 0, 0, 0, 0, 0, 0, 1]
  ))


template testWraps*(queue: untyped) =
  var res = queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  check(res.isNone)
  res = queue.pop(4)
  check(res.isSome)
  check(res.get() == @[1, 2, 3, 4])
  res = queue.push(@[9, 10, 11, 12])
  check(res.isNone)
  check(queue.state == (
    head: 4u,
    tail: 12u,
    storage: @[9, 10, 11, 12, 5, 6, 7, 8]
  ))
  res = queue.pop(4)
  check(res.isSome)
  check(res.get() == @[5, 6, 7, 8])
  check(queue.state == (
    head: 8u,
    tail: 12u,
    storage: @[9, 10, 11, 12, 5, 6, 7, 8]
  ))
  res = queue.pop(4)
  check(res.isSome)
  check(res.get() == @[9, 10, 11, 12])
  check(queue.state == (
    head: 12u,
    tail: 12u,
    storage: @[9, 10, 11, 12, 5, 6, 7, 8]
  ))
