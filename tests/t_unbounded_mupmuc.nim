# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_mupmuc


suite "UnboundedMupmuc":

  test "newUnboundedMupmuc creates valid instance":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    check(queue.segmentCount == 1)

  test "getProducer returns valid producer":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var producer = queue.getProducer()
    check(producer.idx >= 0)

  test "getConsumer returns valid consumer":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var consumer = queue.getConsumer()
    check(consumer.idx >= 0)

  test "producer push single item":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var producer = queue.getProducer()

    producer.push(42)
    check(queue.len == 1)

  test "consumer pop single item":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    producer.push(42)
    let item = consumer.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var consumer = queue.getConsumer()

    let item = consumer.pop()
    check(item.isNone)

  test "FIFO order preserved with single producer and consumer":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    for i in 1..5:
      producer.push(i)

    for i in 1..5:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple producers can push":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)

    var producer1 = queue.getProducer()
    var producer2 = queue.getProducer()
    var consumer = queue.getConsumer()

    for i in 1..5:
      producer1.push(i)
      producer2.push(i + 100)

    check(queue.len == 10)

    var total = 0
    for _ in 1..10:
      let item = consumer.pop()
      check(item.isSome)
      total += item.get

    check(total == 15 + 515)

  test "multiple consumers can pop":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[16, int](manager)
    var producer = queue.getProducer()

    for i in 1..10:
      producer.push(i)

    var consumer1 = queue.getConsumer()
    var consumer2 = queue.getConsumer()

    var count1, count2 = 0
    var total = 0

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
    check(total == 55)

  test "grows beyond single segment":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[4, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    for i in 1..10:
      producer.push(i)

    check(queue.segmentCount >= 3)

    for i in 1..10:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    check(queue.len == 0)

    producer.push(1)
    check(queue.len == 1)

    producer.push(2)
    producer.push(3)
    check(queue.len == 3)

    discard consumer.pop()
    check(queue.len == 2)

    discard consumer.pop()
    discard consumer.pop()
    check(queue.len == 0)

  test "batch push":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    producer.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1..5:
      check(consumer.pop().get == i)

  test "batch pop":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    for i in 1..10:
      producer.push(i)

    let items = consumer.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager)
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()

    producer.push(@[1, 2, 3])

    let items = consumer.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager)
    var consumer = queue.getConsumer()

    let items = consumer.pop(5)
    check(items.isNone)
