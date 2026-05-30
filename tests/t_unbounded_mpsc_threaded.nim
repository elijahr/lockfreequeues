import debra/atomics
import debra/atomics/dsl
import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount
  MaxThreads = 8

type
  ProducerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccMulti, ccSingle, ST, S, MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccMulti, ccSingle, ST, S, MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]

proc producer[ST: static DeallocationStrategy, S: static int](
    ctx: ptr ProducerContext[ST, S]
) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducerHere()
    # Register this producer's debra handle on its own thread.
    let base = ctx.producerIdx * ItemsPerProducer
    for i in 1 .. ItemsPerProducer:
      p.push(base + i)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[ST: static DeallocationStrategy, S: static int](
    ctx: ptr ConsumerContext[ST, S]
) {.thread.} =
  {.cast(gcsafe).}:
    # Register the single-consumer debra handle on the popping thread.
    var lfqConsumer = ctx.queue[].bindConsumer()
    var consumed = 0
    while consumed < ItemCount:
      let item = lfqConsumer.pop()
      if item.isSome:
        let val = item.get - 1 # Items are 1-indexed
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        inc consumed
      elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
        # All producers done but we haven't consumed everything - keep trying
        discard

suite "UnboundedMpsc threaded":
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
    # Auto-create: no registration at construction. The producer threads
    # and the consumer thread each register on their own thread (via
    # attach() / attachConsumer()).
    var queue = newUnboundedMpscQueue[int, stEager, 8, MaxThreads]()
    var lfqConsumer = queue.bindConsumer()

    var prodContexts: array[ProducerCount, ProducerContext[stEager, 8]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[stEager, 8](
        queue: addr queue,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = ConsumerContext[stEager, 8](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
    )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[stEager, 8]]]
    var consThread: Thread[ptr ConsumerContext[stEager, 8]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[stEager, 8], addr prodContexts[i])
    createThread(consThread, consumer[stEager, 8], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    # Auto-create: registration happens per-thread at attach time.
    var queue = newUnboundedMpscQueue[int, stEager, 64, MaxThreads]()
    var lfqConsumer = queue.bindConsumer()

    var prodContexts: array[ProducerCount, ProducerContext[stEager, 64]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[stEager, 64](
        queue: addr queue,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = ConsumerContext[stEager, 64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
    )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[stEager, 64]]]
    var consThread: Thread[ptr ConsumerContext[stEager, 64]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[stEager, 64], addr prodContexts[i])
    createThread(consThread, consumer[stEager, 64], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    # Single-threaded: the main thread is both producer and consumer, so
    # it attaches both handles here.
    var queue = newUnboundedMpscQueue[int, stManual, 8, MaxThreads]()
    var lfqConsumer = queue.bindConsumer()
    # Push items to create segments
    var p = queue.getProducerHere()
    for i in 1 .. 1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    for i in 1 .. 1000:
      discard lfqConsumer.pop()

    # Segments should NOT be freed with Manual (no reclaim called)
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    # Single-threaded: the main thread is both producer and consumer.
    var queue = newUnboundedMpscQueue[int, stEager, 8, MaxThreads]()
    var lfqConsumer = queue.bindConsumer()
    # Push items to create segments
    var p = queue.getProducerHere()
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    for i in 1 .. 1000:
      discard lfqConsumer.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
