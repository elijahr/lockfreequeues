import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_mupmuc

const
  ItemCount = 10000
  ProducerCount = 4
  ConsumerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount

type
  ProducerContext[S: static int] = object
    queue: ptr UnboundedMupmuc[S, int]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedMupmuc[S, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]

proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1 .. ItemsPerProducer:
    p.push(base + i)
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[S: static int](ctx: ptr ConsumerContext[S]) {.thread.} =
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

suite "UnboundedMupmuc threaded":
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

  test "high segment turnover":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager)

    var prodContexts: array[ProducerCount, ProducerContext[8]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[8](
        queue: addr queue, producersDone: addr producersDone, producerIdx: i
      )

    var consContexts: array[ConsumerCount, ConsumerContext[8]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[8](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[8]]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[8]]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[8], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[8], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[64, int](manager)

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

  test "segment retirement (NeverDeallocate)":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager, NeverDeallocate)

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1 .. 1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    var c = queue.getConsumer()
    for i in 1 .. 1000:
      discard c.pop()

    # Segments should NOT be freed with NeverDeallocate
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (EagerDeallocate)":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[8, int](manager, EagerDeallocate)

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    var c = queue.getConsumer()
    for i in 1 .. 1000:
      discard c.pop()

    # Segments SHOULD be freed with EagerDeallocate
    check(queue.segmentCount() <= 3)
