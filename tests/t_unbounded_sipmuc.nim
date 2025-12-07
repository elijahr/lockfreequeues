# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.import atomics
import options
import unittest2

import debra
import lockfreequeues/unbounded_sipmuc


suite "UnboundedSipmuc":

  test "newUnboundedSipmuc creates valid instance":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)
    check(queue.segmentCount == 1)

  test "push single item":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)

    queue.push(42)
    check(queue.len == 1)

  test "push multiple items":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)

    for i in 1..10:
      queue.push(i)
    check(queue.len == 10)

  test "getConsumer returns valid consumer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
    check(consumer.idx >= 0)

  test "consumer pop single item":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)

    queue.push(42)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
    let item = consumer.pop()
    check(item.isSome)
    check(item.get == 42)

  test "consumer pop from empty returns none":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

    let item = consumer.pop()
    check(item.isNone)

  test "FIFO order preserved with single consumer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)

    for i in 1..5:
      queue.push(i)

    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
    for i in 1..5:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple consumers can pop":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)

    for i in 1..10:
      queue.push(i)

    let handle1 = registerThread(manager)
    let handle2 = registerThread(manager)
    var consumer1 = queue.getConsumer(handle1)
    var consumer2 = queue.getConsumer(handle2)

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
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[4, int, 4](addr manager)

    for i in 1..10:
      queue.push(i)

    check(queue.segmentCount >= 3)

    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
    for i in 1..10:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[8, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

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
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[8, int, 4](addr manager)

    queue.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
    for i in 1..5:
      check(consumer.pop().get == i)

  test "batch pop":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[8, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

    for i in 1..10:
      queue.push(i)

    let items = consumer.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[8, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

    queue.push(@[1, 2, 3])

    let items = consumer.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[8, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

    let items = consumer.pop(5)
    check(items.isNone)
