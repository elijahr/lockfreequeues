## Tests for the auto-create constructors and auto-register
## `getProducer()` / `getConsumer()` overloads on the unbounded MP/SP
## variants.

import options
import unittest2

import debra
import lockfreequeues/unbounded_mupmuc
import lockfreequeues/unbounded_sipmuc
import lockfreequeues/unbounded_mupsic

suite "Unbounded auto-create (Mupmuc)":
  test "auto-create: push/pop round-trip and scope-exit teardown":
    block:
      var queue = newUnboundedMupmuc[16, int, 4]()
      var producer = queue.getProducer()
      var consumer = queue.getConsumer()
      producer.push(42)
      check(consumer.pop() == some(42))
      check(consumer.pop() == none(int))
    # Falling out of the block runs `=destroy`, which must (a) drain
    # segments, (b) unbind the client, and (c) destroy + free the
    # privately-owned manager. Reaching this point without an
    # `boundClients == 0` assertion means the unbind path ran.

  test "auto-register getProducer / getConsumer return usable handles":
    var queue = newUnboundedMupmuc[16, int, 4]()
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()
    # idx is per-queue, starts at 0 then 1 etc. The auto-register form
    # also burns one DEBRA thread slot per call; the queue picked
    # MaxThreads=4 so two registrations fit comfortably.
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
    var queue = newUnboundedMupmuc[8, int, 4]()
    var producer = queue.getProducer()
    var consumer = queue.getConsumer()
    producer.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    let got = consumer.pop(10)
    check(got.isSome)
    check(got.get == @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

suite "Unbounded auto-create (Sipmuc)":
  test "auto-create: push/pop round-trip and scope-exit teardown":
    block:
      var queue = newUnboundedSipmuc[16, int, 4]()
      var consumer = queue.getConsumer()
      queue.push(99)
      check(consumer.pop() == some(99))
      check(consumer.pop() == none(int))

  test "auto-register getConsumer returns usable handle":
    var queue = newUnboundedSipmuc[16, int, 4]()
    var consumer = queue.getConsumer()
    check(consumer.idx == 0)
    for i in 1 .. 4:
      queue.push(i * 10)
    var got: seq[int]
    while true:
      let item = consumer.pop()
      if item.isNone:
        break
      got.add(item.get)
    check(got == @[10, 20, 30, 40])

suite "Unbounded auto-create (Mupsic)":
  test "auto-create: caller is the consumer; producer auto-registers":
    block:
      var queue = newUnboundedMupsic[16, int, 4]()
      var producer = queue.getProducer()
      producer.push(7)
      check(queue.pop() == some(7))
      check(queue.pop() == none(int))

  test "auto-register getProducer returns usable handle":
    var queue = newUnboundedMupsic[16, int, 4]()
    var producer = queue.getProducer()
    check(producer.idx == 0)
    for i in 1 .. 3:
      producer.push(i)
    var got: seq[int]
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      got.add(item.get)
    check(got == @[1, 2, 3])

suite "Existing explicit-manager API still works":
  test "explicit: shared manager across multiple Mupmuc queues":
    var manager = initDebraManager[4]()
    var queueA = newUnboundedMupmuc[16, int, 4](addr manager)
    var queueB = newUnboundedMupmuc[16, int, 4](addr manager)

    let handle = registerThread(manager)
    var producerA = queueA.getProducer(handle)
    var consumerA = queueA.getConsumer(handle)
    var producerB = queueB.getProducer(handle)
    var consumerB = queueB.getConsumer(handle)

    producerA.push(1)
    producerB.push(2)
    check(consumerA.pop() == some(1))
    check(consumerB.pop() == some(2))

  test "explicit: Sipmuc with shared manager":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, int, 4](addr manager)
    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
    queue.push(123)
    check(consumer.pop() == some(123))

  test "explicit: Mupsic with shared manager and explicit consumer handle":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[16, int, 4](addr manager, consumerHandle)
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    producer.push(456)
    check(queue.pop() == some(456))
