import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

from debra import DebraManager, registerThread
import ./debra_cc_helpers

const
  ItemCount = 10000
  ConsumerCount = 4
  MaxThreads = 8

type
  ProducerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccSingle, ccMulti, ST, rkEbr, 0, 0, 0, S, MaxThreads]
    producerDone: ptr Atomic[bool]

  ConsumerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccSingle, ccMulti, ST, rkEbr, 0, 0, 0, S, MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]

proc producer[ST: static DeallocationStrategy, S: static int](
    ctx: ptr ProducerContext[ST, S]
) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducer()
    for i in 1 .. ItemCount:
      p.push(i)
    ctx.producerDone[].store(true, moRelease)

proc consumer[ST: static DeallocationStrategy, S: static int](
    ctx: ptr ConsumerContext[ST, S]
) {.thread.} =
  {.cast(gcsafe).}:
    var c = ctx.queue[].getConsumer()
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
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedSipmucQueue[int, stEager, 8, MaxThreads](addr manager)
    var prodCtx =
      ProducerContext[stEager, 8](queue: addr queue, producerDone: addr producerDone)
    var consCtxs: array[ConsumerCount, ConsumerContext[stEager, 8]]
    for i in 0 ..< ConsumerCount:
      consCtxs[i] = ConsumerContext[stEager, 8](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThread: Thread[ptr ProducerContext[stEager, 8]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[stEager, 8]]]

    createThread(prodThread, producer[stEager, 8], addr prodCtx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[stEager, 8], addr consCtxs[i])

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedSipmucQueue[int, stEager, 64, MaxThreads](addr manager)
    var prodCtx =
      ProducerContext[stEager, 64](queue: addr queue, producerDone: addr producerDone)
    var consCtxs: array[ConsumerCount, ConsumerContext[stEager, 64]]
    for i in 0 ..< ConsumerCount:
      consCtxs[i] = ConsumerContext[stEager, 64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThread: Thread[ptr ProducerContext[stEager, 64]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[stEager, 64]]]

    createThread(prodThread, producer[stEager, 64], addr prodCtx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[stEager, 64], addr consCtxs[i])

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedSipmucQueue[int, stManual, 8, MaxThreads](addr manager)

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1 .. 1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    var c = queue.getConsumer()
    for i in 1 .. 1000:
      discard c.pop()

    # Segments should NOT be freed with Manual (no reclaim called)
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedSipmucQueue[int, stEager, 8, MaxThreads](addr manager)

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    var c = queue.getConsumer()
    for i in 1 .. 1000:
      discard c.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
