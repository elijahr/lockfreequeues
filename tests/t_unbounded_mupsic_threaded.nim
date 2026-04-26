import lockfreequeues/atomic_dsl
import options
import unittest2

import debra
import lockfreequeues/unbounded_mupsic

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount
  MaxThreads = 8

type
  ProducerContext[S: static int] = object
    queue: ptr UnboundedMupsic[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedMupsic[S, int, MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]

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
    var consumed = 0
    while consumed < ItemCount:
      let item = ctx.queue[].pop()
      if item.isSome:
        let val = item.get - 1 # Items are 1-indexed
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        inc consumed
      elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
        # All producers done but we haven't consumed everything - keep trying
        discard

suite "UnboundedMupsic threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)

  test "high segment turnover":
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, MaxThreads](addr manager, consumerHandle)

    var prodContexts: array[ProducerCount, ProducerContext[8]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[8](
        queue: addr queue,
        manager: addr manager,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = ConsumerContext[8](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
    )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[8]]]
    var consThread: Thread[ptr ConsumerContext[8]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[8], addr prodContexts[i])
    createThread(consThread, consumer[8], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[64, int, MaxThreads](addr manager, consumerHandle)

    var prodContexts: array[ProducerCount, ProducerContext[64]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[64](
        queue: addr queue,
        manager: addr manager,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = ConsumerContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
    )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[64]]]
    var consThread: Thread[ptr ConsumerContext[64]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[64], addr prodContexts[i])
    createThread(consThread, consumer[64], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue =
      newUnboundedMupsic[8, int, MaxThreads](addr manager, consumerHandle, Manual)

    # Push items to create segments
    let producerHandle = registerThread(manager)
    var p = queue.getProducer(producerHandle)
    for i in 1 .. 1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    for i in 1 .. 1000:
      discard queue.pop()

    # Segments should NOT be freed with Manual (no reclaim called)
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue =
      newUnboundedMupsic[8, int, MaxThreads](addr manager, consumerHandle, Eager)

    # Push items to create segments
    let producerHandle = registerThread(manager)
    var p = queue.getProducer(producerHandle)
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    for i in 1 .. 1000:
      discard queue.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
