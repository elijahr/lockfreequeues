import atomics
import options
import unittest2

import debra
import lockfreequeues/unbounded_mupsic

suite "UnboundedMupsic":
  test "newUnboundedMupsic creates valid instance":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    check(queue.segmentCount == 1)

  test "getProducer returns valid producer":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    check(producer.idx >= 0)

  test "producer push single item":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    producer.push(42)
    check(queue.len == 1)

  test "producer push multiple items":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    for i in 1 .. 10:
      producer.push(i)
    check(queue.len == 10)

  test "pop single item":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    producer.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved with single producer":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    for i in 1 .. 5:
      producer.push(i)

    for i in 1 .. 5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple producers can push":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)

    let producerHandle1 = registerThread(manager)
    let producerHandle2 = registerThread(manager)
    var producer1 = queue.getProducer(producerHandle1)
    var producer2 = queue.getProducer(producerHandle2)

    # Each producer pushes
    for i in 1 .. 5:
      producer1.push(i)
      producer2.push(i + 100)

    check(queue.len == 10)

    # Pop all items
    var total = 0
    for _ in 1 .. 10:
      let item = queue.pop()
      check(item.isSome)
      total += item.get

    check(total == 15 + 515) # sum(1..5) + sum(101..105)

  test "grows beyond single segment":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[4, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    for i in 1 .. 10:
      producer.push(i)

    check(queue.segmentCount >= 3)

    for i in 1 .. 10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

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
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    producer.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1 .. 5:
      check(queue.pop().get == i)

  test "batch pop":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    for i in 1 .. 10:
      producer.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    producer.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, 4](addr manager, consumerHandle)

    let items = queue.pop(5)
    check(items.isNone)
