import lockfreequeues/atomic_dsl
import options
import unittest2

import debra
import lockfreequeues/unbounded_sipmuc

const
  ItemCount = 10000
  ConsumerCount = 4
  MaxThreads = 8

type
  ProducerContext[S: static int] = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    producerDone: ptr Atomic[bool]

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]

proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    for i in 1 .. ItemCount:
      ctx.queue[].push(i)
    ctx.producerDone[].store(true, moRelease)

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
      elif ctx.producerDone[].load(moAcquire):
        if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
          break

suite "UnboundedSipmuc threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]
    totalConsumed: Atomic[int]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

  test "high segment turnover":
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedSipmuc[8, int, MaxThreads](addr manager)
    var prodCtx = ProducerContext[8](queue: addr queue, producerDone: addr producerDone)
    var consCtxs: array[ConsumerCount, ConsumerContext[8]]
    for i in 0 ..< ConsumerCount:
      consCtxs[i] = ConsumerContext[8](
        queue: addr queue,
        manager: addr manager,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThread: Thread[ptr ProducerContext[8]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[8]]]

    createThread(prodThread, producer[8], addr prodCtx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[8], addr consCtxs[i])

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedSipmuc[64, int, MaxThreads](addr manager)
    var prodCtx = ProducerContext[64](queue: addr queue, producerDone: addr producerDone)
    var consCtxs: array[ConsumerCount, ConsumerContext[64]]
    for i in 0 ..< ConsumerCount:
      consCtxs[i] = ConsumerContext[64](
        queue: addr queue,
        manager: addr manager,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThread: Thread[ptr ProducerContext[64]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[64]]]

    createThread(prodThread, producer[64], addr prodCtx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[64], addr consCtxs[i])

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedSipmuc[8, int, MaxThreads](addr manager, Manual)

    # Push items to create segments
    for i in 1 .. 1000:
      queue.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    let handle = registerThread(manager)
    var c = queue.getConsumer(handle)
    for i in 1 .. 1000:
      discard c.pop()

    # Segments should NOT be freed with Manual (no reclaim called)
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    var manager = initDebraManager[MaxThreads]()
    var queue = newUnboundedSipmuc[8, int, MaxThreads](addr manager, Eager)

    # Push items to create segments
    for i in 1 .. 1000:
      queue.push(i)

    # Pop all items
    let handle = registerThread(manager)
    var c = queue.getConsumer(handle)
    for i in 1 .. 1000:
      discard c.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
