import lockfreequeues/atomic_dsl
import options
import unittest2

import debra
import lockfreequeues/unbounded_mupmuc

const
  ItemCount = 10000
  ProducerCount = 4
  ConsumerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount
  MaxThreads = 16

type
  ProducerContext[S: static int] = object
    queue: ptr UnboundedMupmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedMupmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]

proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(handle)
    let base = ctx.producerIdx * ItemsPerProducer
    for i in 1 .. ItemsPerProducer:
      p.push(base + i)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[S: static int](ctx: ptr ConsumerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(handle)
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
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedMupmuc[8, int, MaxThreads](addr manager)

    var prodContexts: array[ProducerCount, ProducerContext[8]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[8](
        queue: addr queue,
        manager: addr manager,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consContexts: array[ConsumerCount, ConsumerContext[8]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[8](
        queue: addr queue,
        manager: addr manager,
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
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedMupmuc[64, int, MaxThreads](addr manager)

    var prodContexts: array[ProducerCount, ProducerContext[64]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[64](
        queue: addr queue,
        manager: addr manager,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consContexts: array[ConsumerCount, ConsumerContext[64]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[64](
        queue: addr queue,
        manager: addr manager,
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

  test "segment retirement (Manual)":
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedMupmuc[8, int, MaxThreads](addr manager, Manual)

    # Push items to create segments
    let producerHandle = registerThread(manager)
    var p = queue.getProducer(producerHandle)
    for i in 1 .. 1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    let consumerHandle = registerThread(manager)
    var c = queue.getConsumer(consumerHandle)
    for i in 1 .. 1000:
      discard c.pop()

    # Segments should NOT be freed with Manual (no reclaim called)
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedMupmuc[8, int, MaxThreads](addr manager, Eager)

    # Push items to create segments
    let producerHandle = registerThread(manager)
    var p = queue.getProducer(producerHandle)
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    let consumerHandle = registerThread(manager)
    var c = queue.getConsumer(consumerHandle)
    for i in 1 .. 1000:
      discard c.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
