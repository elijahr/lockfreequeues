import lockfreequeues/atomic_dsl
import options
import unittest2

import debra
import lockfreequeues/unbounded_mupmuc

suite "UnboundedMupmuc":
  test "newUnboundedMupmuc creates valid instance":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    check(queue.segmentCount == 1)

  test "getProducer returns valid producer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    check(producer.idx >= 0)

  test "getConsumer returns valid consumer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let consumerHandle = registerThread(manager)
    var consumer = queue.getConsumer(consumerHandle)
    check(consumer.idx >= 0)

  test "producer push single item":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    producer.push(42)
    check(queue.len == 1)

  test "consumer pop single item":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

    producer.push(42)
    let item = consumer.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let consumerHandle = registerThread(manager)
    var consumer = queue.getConsumer(consumerHandle)

    let item = consumer.pop()
    check(item.isNone)

  test "FIFO order preserved with single producer and consumer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

    for i in 1 .. 5:
      producer.push(i)

    for i in 1 .. 5:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple producers can push":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)

    let producerHandle1 = registerThread(manager)
    let producerHandle2 = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer1 = queue.getProducer(producerHandle1)
    var producer2 = queue.getProducer(producerHandle2)
    var consumer = queue.getConsumer(consumerHandle)

    for i in 1 .. 5:
      producer1.push(i)
      producer2.push(i + 100)

    check(queue.len == 10)

    var total = 0
    for _ in 1 .. 10:
      let item = consumer.pop()
      check(item.isSome)
      total += item.get

    check(total == 15 + 515)

  test "multiple consumers can pop":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    for i in 1 .. 10:
      producer.push(i)

    let consumerHandle1 = registerThread(manager)
    let consumerHandle2 = registerThread(manager)
    var consumer1 = queue.getConsumer(consumerHandle1)
    var consumer2 = queue.getConsumer(consumerHandle2)

    var count1, count2 = 0
    var total = 0

    for _ in 1 .. 5:
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
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[4, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

    for i in 1 .. 10:
      producer.push(i)

    check(queue.segmentCount >= 3)

    for i in 1 .. 10:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[8, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

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
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[8, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

    producer.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1 .. 5:
      check(consumer.pop().get == i)

  test "batch pop":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[8, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

    for i in 1 .. 10:
      producer.push(i)

    let items = consumer.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[8, int, 4](addr manager)
    let producerHandle = registerThread(manager)
    let consumerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var consumer = queue.getConsumer(consumerHandle)

    producer.push(@[1, 2, 3])

    let items = consumer.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[8, int, 4](addr manager)
    let consumerHandle = registerThread(manager)
    var consumer = queue.getConsumer(consumerHandle)

    let items = consumer.pop(5)
    check(items.isNone)
