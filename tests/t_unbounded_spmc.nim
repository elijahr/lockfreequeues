import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

import debra as debra_mod
from debra import DebraManager, initDebraManager, registerThread

suite "UnboundedSpmc":
  test "newUnboundedSpmcQueue creates valid instance":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    check(queue.segmentCount == 1)

  test "push single item":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = queue.getProducerHere()

    producer.push(42)
    check(queue.len == 1)

  test "push multiple items":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = queue.getProducerHere()

    for i in 1 .. 10:
      producer.push(i)
    check(queue.len == 10)

  test "getConsumer returns valid consumer":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var consumer = queue.getConsumerHere()
    check(consumer.idx >= 0)

  test "consumer pop single item":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = queue.getProducerHere()

    producer.push(42)
    var consumer = queue.getConsumerHere()
    let item = consumer.pop()
    check(item.isSome)
    check(item.get == 42)

  test "consumer pop from empty returns none":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var consumer = queue.getConsumerHere()

    let item = consumer.pop()
    check(item.isNone)

  test "FIFO order preserved with single consumer":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = queue.getProducerHere()

    for i in 1 .. 5:
      producer.push(i)

    var consumer = queue.getConsumerHere()
    for i in 1 .. 5:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "multiple consumers can pop":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = queue.getProducerHere()

    for i in 1 .. 10:
      producer.push(i)

    var consumer1 = queue.getConsumerHere()
    var consumer2 = queue.getConsumerHere()

    var count1, count2 = 0
    var total = 0

    # Each consumer tries to pop
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
    check(total == 55) # sum of 1..10

  test "grows beyond single segment":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 4, 4](addr manager)
    var producer = queue.getProducerHere()

    for i in 1 .. 10:
      producer.push(i)

    check(queue.segmentCount >= 3)

    var consumer = queue.getConsumerHere()
    for i in 1 .. 10:
      let item = consumer.pop()
      check(item.isSome)
      check(item.get == i)

  test "len tracks items correctly":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 8, 4](addr manager)
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()

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
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 8, 4](addr manager)
    var producer = queue.getProducerHere()

    producer.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    var consumer = queue.getConsumerHere()
    for i in 1 .. 5:
      check(consumer.pop().get == i)

  test "batch pop":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 8, 4](addr manager)
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()

    for i in 1 .. 10:
      producer.push(i)

    let items = consumer.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 8, 4](addr manager)
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()

    producer.push(@[1, 2, 3])

    let items = consumer.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 8, 4](addr manager)
    var consumer = queue.getConsumerHere()

    let items = consumer.pop(5)
    check(items.isNone)
