# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest


import lockfreequeues/producer
import ./t_sic


template testMupPush*(queue: untyped) =
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


template testMupPushOverflow*(queue: untyped) =
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


template testMupPushWrap*(queue: untyped) =
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


template testMupPushSeq*(queue: untyped) =
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


template testMupPushSeqOverflow*(queue: untyped) =
  let res = queue.push(0,
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


template testMupPushSeqWrap*(queue: untyped) =
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
