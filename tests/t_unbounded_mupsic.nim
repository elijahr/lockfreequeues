# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_mupsic


suite "UnboundedMupsic":

  test "newUnboundedMupsic creates valid instance":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)
    check(queue.segmentCount == 1)

  test "getProducer returns valid producer":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)
    var producer = queue.getProducer()
    check(producer.idx >= 0)

  test "producer push single item":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)
    var producer = queue.getProducer()

    producer.push(42)
    check(queue.len == 1)

  test "producer push multiple items":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)
    var producer = queue.getProducer()

    for i in 1..10:
      producer.push(i)
    check(queue.len == 10)

  test "pop single item":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)
    var producer = queue.getProducer()

    producer.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved with single producer":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)
    var producer = queue.getProducer()

    for i in 1..5:
      producer.push(i)

    for i in 1..5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple producers can push":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[16, int](manager)

    var producer1 = queue.getProducer()
    var producer2 = queue.getProducer()

    # Each producer pushes
    for i in 1..5:
      producer1.push(i)
      producer2.push(i + 100)

    check(queue.len == 10)

    # Pop all items
    var total = 0
    for _ in 1..10:
      let item = queue.pop()
      check(item.isSome)
      total += item.get

    check(total == 15 + 515)  # sum(1..5) + sum(101..105)

  test "grows beyond single segment":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[4, int](manager)
    var producer = queue.getProducer()

    for i in 1..10:
      producer.push(i)

    check(queue.segmentCount >= 3)

    for i in 1..10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager)
    var producer = queue.getProducer()

    check(queue.len == 0)

    producer.push(1)
    check(queue.len == 1)

    producer.push(2)
    producer.push(3)
    check(queue.len == 3)

    discard queue.pop()
    check(queue.len == 2)

    discard queue.pop()
    discard queue.pop()
    check(queue.len == 0)

  test "batch push":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager)
    var producer = queue.getProducer()

    producer.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1..5:
      check(queue.pop().get == i)

  test "batch pop":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager)
    var producer = queue.getProducer()

    for i in 1..10:
      producer.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager)
    var producer = queue.getProducer()

    producer.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager)

    let items = queue.pop(5)
    check(items.isNone)
