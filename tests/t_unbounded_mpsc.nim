import debra/atomics
import debra/atomics/dsl
import options
import unittest2

import debra
import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "UnboundedMpsc":
  test "newUnboundedMpscQueue creates valid instance":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    check(queue.segmentCount == 1)

  test "getProducer returns valid producer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()
    check(producer.idx >= 0)

  test "producer push single item":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    producer.push(42)
    check(queue.len == 1)

  test "producer push multiple items":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    for i in 1 .. 10:
      producer.push(i)
    check(queue.len == 10)

  test "pop single item":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    producer.push(42)
    let item = lfqConsumer.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()

    let item = lfqConsumer.pop()
    check(item.isNone)

  test "FIFO order preserved with single producer":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    for i in 1 .. 5:
      producer.push(i)

    for i in 1 .. 5:
      let item = lfqConsumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple producers can push":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()

    var producer1 = queue.getProducerHere()
    var producer2 = queue.getProducerHere()

    # Each producer pushes
    for i in 1 .. 5:
      producer1.push(i)
      producer2.push(i + 100)

    check(queue.len == 10)

    # Pop all items
    var total = 0
    for _ in 1 .. 10:
      let item = lfqConsumer.pop()
      check(item.isSome)
      total += item.get

    check(total == 15 + 515) # sum(1..5) + sum(101..105)

  test "grows beyond single segment":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 4, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    for i in 1 .. 10:
      producer.push(i)

    check(queue.segmentCount >= 3)

    for i in 1 .. 10:
      let item = lfqConsumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 8, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    check(queue.len == 0)

    producer.push(1)
    check(queue.len == 1)

    producer.push(2)
    producer.push(3)
    check(queue.len == 3)

    discard lfqConsumer.pop()
    check(queue.len == 2)

    discard lfqConsumer.pop()
    discard lfqConsumer.pop()
    check(queue.len == 0)

  test "batch push":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 8, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    producer.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1 .. 5:
      check(lfqConsumer.pop().get == i)

  test "batch pop":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 8, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    for i in 1 .. 10:
      producer.push(i)

    let items = lfqConsumer.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 8, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()

    producer.push(@[1, 2, 3])

    let items = lfqConsumer.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMpscQueue[int, stEager, 8, 4](addr manager)
    var lfqConsumer = queue.bindConsumer()

    let items = lfqConsumer.pop(5)
    check(items.isNone)
