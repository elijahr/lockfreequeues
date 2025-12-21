import atomics
import options
import unittest2

import lockfreequeues

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

proc producer[N: static int](ctx: ptr ProducerContext[N]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1 .. ItemsPerProducer:
    while not p.push(base + i):
      discard
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[N: static int](ctx: ptr ConsumerContext[N]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1 # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
        break
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
        break

suite "Mupmuc threaded":
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

  test "high contention":
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
      createThread(prodThreads[i], producer[16], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[16], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal capacity":
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
      createThread(prodThreads[i], producer[64], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[64], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
