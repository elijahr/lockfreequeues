## Tests for the auto-create constructors and auto-register
## `getProducer()` / `getConsumer()` overloads on the unbounded MP/SP
## variants of the unified Queue.
##
## v5.0.0 cascade migration: the legacy `newUnboundedMpmc` /
## `newUnboundedSpmc` / `newUnboundedMpsc` constructors collapsed
## into the smart-constructors `newUnboundedMpmcQueue` /
## `newUnboundedSpmcQueue` / `newUnboundedMpscQueue`. The auto-create
## overload returns a Queue with a privately-owned `DebraManager`; the
## borrow overload takes `ptr DebraManager` as the first arg.

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

suite "Unbounded auto-create (Mpmc)":
  test "auto-create: push/pop round-trip and scope-exit teardown":
    block:
      var queue = newUnboundedMpmcQueue[int, stEager, 16, 4]()
      var producer = queue.getProducerHere()
      var consumer = queue.getConsumerHere()
      producer.push(42)
      check(consumer.pop() == some(42))
      check(consumer.pop() == none(int))
    # Falling out of the block runs `=destroy`, which must (a) drain
    # segments, (b) unbind the client, and (c) destroy + free the
    # privately-owned manager.

  test "auto-register getProducer / getConsumer return usable handles":
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4]()
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()
    # idx is per-queue, starts at 0 then 1 etc. attach() burns one DEBRA
    # thread slot per registering thread; the queue picked MaxThreads=4
    # so two registrations fit comfortably.
    check(producer.idx == 0)
    check(consumer.idx == 0)
    for i in 1 .. 5:
      producer.push(i)
    var got: seq[int]
    while true:
      let item = consumer.pop()
      if item.isNone:
        break
      got.add(item.get)
    check(got == @[1, 2, 3, 4, 5])

  test "auto-create: bulk push/pop":
    var queue = newUnboundedMpmcQueue[int, stEager, 8, 4]()
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()
    producer.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    let got = consumer.pop(10)
    check(got.isSome)
    check(got.get == @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

suite "Unbounded auto-create (Spmc)":
  test "auto-create: push/pop round-trip and scope-exit teardown":
    block:
      var queue = newUnboundedSpmcQueue[int, stEager, 16, 4]()
      var producer = queue.getProducerHere()
      var consumer = queue.getConsumerHere()
      producer.push(99)
      check(consumer.pop() == some(99))
      check(consumer.pop() == none(int))

  test "auto-register getConsumer returns usable handle":
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4]()
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()
    check(consumer.idx == 0)
    for i in 1 .. 4:
      producer.push(i * 10)
    var got: seq[int]
    while true:
      let item = consumer.pop()
      if item.isNone:
        break
      got.add(item.get)
    check(got == @[10, 20, 30, 40])

suite "Unbounded auto-create (Mpsc)":
  test "auto-create: caller is the consumer; producer auto-registers":
    block:
      var queue = newUnboundedMpscQueue[int, stEager, 16, 4]()
      # Single-threaded: this thread is both producer and consumer.
      var lfqConsumer = queue.bindConsumer()
      var producer = queue.getProducerHere()
      producer.push(7)
      check(lfqConsumer.pop() == some(7))
      check(lfqConsumer.pop() == none(int))

  test "auto-register getProducer returns usable handle":
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4]()
    var lfqConsumer = queue.bindConsumer()
    var producer = queue.getProducerHere()
    check(producer.idx == 0)
    for i in 1 .. 3:
      producer.push(i)
    var got: seq[int]
    while true:
      let item = lfqConsumer.pop()
      if item.isNone:
        break
      got.add(item.get)
    check(got == @[1, 2, 3])

suite "Existing borrow-manager API still works":
  test "borrow: shared manager across multiple Mpmc queues":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queueA = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    var queueB = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)

    var producerA = queueA.getProducerHere()
    var consumerA = queueA.getConsumerHere()
    var producerB = queueB.getProducerHere()
    var consumerB = queueB.getConsumerHere()

    producerA.push(1)
    producerB.push(2)
    check(consumerA.pop() == some(1))
    check(consumerB.pop() == some(2))

  test "borrow: Spmc with shared manager":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedSpmcQueue[int, stEager, 16, 4](addr manager)
    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()
    producer.push(123)
    check(consumer.pop() == some(123))

  test "borrow: Mpsc with shared manager and explicit consumer handle":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMpscQueue[int, stEager, 16, 4](
        addr manager, consumerHandle)
    # Escape hatch: the consumer handle was registered + supplied at
    # construction (consumerAttached set true there). The producer still
    # registers on its operating thread via attach().
    var producer = queue.getProducerHere()
    producer.push(456)
    check(lfqConsumer.pop() == some(456))
