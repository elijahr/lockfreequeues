import options
import unittest2
import lockfreequeues
import lockfreequeues/atomic_dsl

const
  ItemCount = 10000
  ProducerCount = 4
  ConsumerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount

type
  ProducerContext[N: static int] = object
    queue: ptr Mupmuc[N, ProducerCount, ConsumerCount, int]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[N: static int] = object
    queue: ptr Mupmuc[N, ProducerCount, ConsumerCount, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]

proc mupmucProducer[N: static int](ctx: ptr ProducerContext[N]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1 .. ItemsPerProducer:
    while not p.push(base + i):
      discard
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc mupmucConsumer[N: static int](ctx: ptr ConsumerContext[N]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
        break
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
        break

suite "Legacy Mupmuc - Single-threaded":
  test "capacity and producer/consumer counts":
    var q = initMupmuc[8, 4, 4, int]()
    check(q.capacity == 8)
    check(q.producerCount == 4)
    check(q.consumerCount == 4)
    check(q.empty == true)
    check(q.full == false)

  test "producer push and consumer pop FIFO":
    var q = initMupmuc[8, 4, 4, int]()
    var p0 = q.getProducer(0)
    var c0 = q.getConsumer(0)

    for i in 1 .. 8:
      check(p0.push(i) == true)
    check(q.full == true)
    check(p0.push(999) == false)

    for i in 1 .. 8:
      let item = c0.pop()
      check(item.isSome)
      check(item.get == i)
    check(q.empty == true)
    check(c0.pop().isNone)

  test "multiple producers and consumers interleaving":
    var q = initMupmuc[8, 2, 2, int]()
    var p0 = q.getProducer(0)
    var p1 = q.getProducer(1)
    var c0 = q.getConsumer(0)
    var c1 = q.getConsumer(1)

    check(p0.push(11) == true)
    check(p1.push(22) == true)
    check(p0.push(33) == true)
    check(p1.push(44) == true)

    check(c0.pop().get == 11)
    check(c1.pop().get == 22)
    check(c0.pop().get == 33)
    check(c1.pop().get == 44)
    check(q.empty == true)

  test "batch push and batch pop":
    var q = initMupmuc[8, 2, 2, int]()
    var p0 = q.getProducer(0)
    var c0 = q.getConsumer(0)

    let rem = p0.push(@[5, 10, 15, 20])
    check(rem.isNone)

    let popped = c0.pop(4)
    check(popped.isSome)
    check(popped.get == @[5, 10, 15, 20])
    check(q.empty == true)

suite "Legacy Mupmuc - Multi-threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]
    totalConsumed: Atomic[int]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)

  test "threaded high contention (N=16, P=4, C=4)":
    var queue = initMupmuc[16, ProducerCount, ConsumerCount, int]()

    var prodContexts: array[ProducerCount, ProducerContext[16]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[16](
        queue: addr queue, producersDone: addr producersDone, producerIdx: i
      )

    var consContexts: array[ConsumerCount, ConsumerContext[16]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[16]]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[16]]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], mupmucProducer[16], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], mupmucConsumer[16], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "threaded normal capacity (N=64, P=4, C=4)":
    var queue = initMupmuc[64, ProducerCount, ConsumerCount, int]()

    var prodContexts: array[ProducerCount, ProducerContext[64]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[64](
        queue: addr queue, producersDone: addr producersDone, producerIdx: i
      )

    var consContexts: array[ConsumerCount, ConsumerContext[64]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[64]]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[64]]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], mupmucProducer[64], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], mupmucConsumer[64], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
