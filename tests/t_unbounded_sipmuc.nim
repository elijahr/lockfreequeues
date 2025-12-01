# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_sipmuc


suite "UnboundedSipmuc":

  test "newUnboundedSipmuc creates valid instance":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)
    check(queue.segmentCount == 1)

  test "push single item":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)

    queue.push(42)
    check(queue.len == 1)

  test "push multiple items":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)

    for i in 1..10:
      queue.push(i)
    check(queue.len == 10)

  test "getConsumer returns valid consumer":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)
    var consumer = queue.getConsumer()
    check(consumer.idx >= 0)

  test "consumer pop single item":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)

    queue.push(42)
    var consumer = queue.getConsumer()
    let item = consumer.pop()
    check(item.isSome)
    check(item.get == 42)

  test "consumer pop from empty returns none":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)
    var consumer = queue.getConsumer()

    let item = consumer.pop()
    check(item.isNone)

  test "FIFO order preserved with single consumer":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)

    for i in 1..5:
      queue.push(i)

    var consumer = queue.getConsumer()
    for i in 1..5:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple consumers can pop":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[16, int](manager)

    for i in 1..10:
      queue.push(i)

    var consumer1 = queue.getConsumer()
    var consumer2 = queue.getConsumer()

    var count1, count2 = 0
    var total = 0

    # Each consumer tries to pop
    for _ in 1..5:
      let item1 = consumer1.pop()
      if item1.isSome:
        inc count1
        total += item1.get
      let item2 = consumer2.pop()
      if item2.isSome:
        inc count2
        total += item2.get

    check(count1 + count2 == 10)
    check(total == 55)  # sum of 1..10

  test "grows beyond single segment":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[4, int](manager)

    for i in 1..10:
      queue.push(i)

    check(queue.segmentCount >= 3)

    var consumer = queue.getConsumer()
    for i in 1..10:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager)
    var consumer = queue.getConsumer()

    check(queue.len == 0)

    queue.push(1)
    check(queue.len == 1)

    queue.push(2)
    queue.push(3)
    check(queue.len == 3)

    discard consumer.pop()
    check(queue.len == 2)

    discard consumer.pop()
    discard consumer.pop()
    check(queue.len == 0)

  test "batch push":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager)

    queue.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    var consumer = queue.getConsumer()
    for i in 1..5:
      check(consumer.pop().get == i)

  test "batch pop":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager)
    var consumer = queue.getConsumer()

    for i in 1..10:
      queue.push(i)

    let items = consumer.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager)
    var consumer = queue.getConsumer()

    queue.push(@[1, 2, 3])

    let items = consumer.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager)
    var consumer = queue.getConsumer()

    let items = consumer.pop(5)
    check(items.isNone)
