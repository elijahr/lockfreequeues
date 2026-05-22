import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

from debra import initDebraManager, registerThread

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount
  MaxThreads = 8

type
  ProducerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccMulti, ccSingle, ST, rkEbr, 0, 0, 0, S, MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[ST: static DeallocationStrategy, S: static int] = object
    queue: ptr Queue[int, ccMulti, ccSingle, ST, rkEbr, 0, 0, 0, S, MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]

proc producer[ST: static DeallocationStrategy, S: static int](
    ctx: ptr ProducerContext[ST, S]
) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducer()
    let base = ctx.producerIdx * ItemsPerProducer
    for i in 1 .. ItemsPerProducer:
      p.push(base + i)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[ST: static DeallocationStrategy, S: static int](
    ctx: ptr ConsumerContext[ST, S]
) {.thread.} =
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
    var queue =
      newUnboundedMupsicQueue[int, stEager, 8, MaxThreads](addr manager, consumerHandle)

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
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue =
      newUnboundedMupsicQueue[int, stEager, 64, MaxThreads](addr manager, consumerHandle)

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
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsicQueue[int, stManual, 8, MaxThreads](
      addr manager, consumerHandle
    )

    # Push items to create segments
    var p = queue.getProducer()
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
    var queue = newUnboundedMupsicQueue[int, stEager, 8, MaxThreads](
      addr manager, consumerHandle
    )

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    for i in 1 .. 1000:
      discard queue.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
