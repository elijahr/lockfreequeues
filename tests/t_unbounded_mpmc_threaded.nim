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

from debra import DebraManager, registerThread
import ./debra_cc_helpers

const
  ItemCount = 10000
  ProducerCount = 4
  ConsumerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount
  MaxThreads = 16

type
  ProducerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccMulti, ccMulti, ST, S, MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccMulti, ccMulti, ST, S, MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]

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
    var c = ctx.queue[].getConsumerHere()
    # Register this consumer's debra handle on its own thread.
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

suite "UnboundedMpmc threaded":
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
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedMpmcQueue[int, stEager, 8, MaxThreads](addr manager)

    var prodContexts: array[ProducerCount, ProducerContext[stEager, 8]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[stEager, 8](
        queue: addr queue,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consContexts: array[ConsumerCount, ConsumerContext[stEager, 8]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[stEager, 8](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[stEager, 8]]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[stEager, 8]]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[stEager, 8], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[stEager, 8], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedMpmcQueue[int, stEager, 64, MaxThreads](addr manager)

    var prodContexts: array[ProducerCount, ProducerContext[stEager, 64]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[stEager, 64](
        queue: addr queue,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consContexts: array[ConsumerCount, ConsumerContext[stEager, 64]]
    for i in 0 ..< ConsumerCount:
      consContexts[i] = ConsumerContext[stEager, 64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        totalConsumed: addr totalConsumed,
      )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[stEager, 64]]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[stEager, 64]]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[stEager, 64], addr prodContexts[i])
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[stEager, 64], addr consContexts[i])

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedMpmcQueue[int, stManual, 8, MaxThreads](addr manager)

    # Push items to create segments
    var p = queue.getProducerHere()
    for i in 1 .. 1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    var c = queue.getConsumerHere()
    for i in 1 .. 1000:
      discard c.pop()

    # Segments should NOT be freed with Manual (no reclaim called)
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue = newUnboundedMpmcQueue[int, stEager, 8, MaxThreads](addr manager)

    # Push items to create segments
    var p = queue.getProducerHere()
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    var c = queue.getConsumerHere()
    for i in 1 .. 1000:
      discard c.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
