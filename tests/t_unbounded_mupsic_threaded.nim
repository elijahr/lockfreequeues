import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_mupsic


const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount


type
  TestContext[S: static int] = object
    queue: ptr UnboundedMupsic[S, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    producerIdx: int


proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1..ItemsPerProducer:
    p.push(base + i)
  discard ctx.producersDone[].fetchAdd(1, moRelease)


proc consumer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
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
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)

  test "high segment turnover":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager)

    var contexts: array[ProducerCount, TestContext[8]]
    for i in 0..<ProducerCount:
      contexts[i] = TestContext[8](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: i
      )

    var consCtx = TestContext[8](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0
    )

    var prodThreads: array[ProducerCount, Thread[ptr TestContext[8]]]
    var consThread: Thread[ptr TestContext[8]]

    for i in 0..<ProducerCount:
      createThread(prodThreads[i], producer[8], addr contexts[i])
    createThread(consThread, consumer[8], addr consCtx)

    for i in 0..<ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0..<ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[64, int](manager)

    var contexts: array[ProducerCount, TestContext[64]]
    for i in 0..<ProducerCount:
      contexts[i] = TestContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: i
      )

    var consCtx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0
    )

    var prodThreads: array[ProducerCount, Thread[ptr TestContext[64]]]
    var consThread: Thread[ptr TestContext[64]]

    for i in 0..<ProducerCount:
      createThread(prodThreads[i], producer[64], addr contexts[i])
    createThread(consThread, consumer[64], addr consCtx)

    for i in 0..<ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0..<ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (NeverDeallocate)":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager, NeverDeallocate)

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1..1000:
      p.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    for i in 1..1000:
      discard queue.pop()

    # Segments should NOT be freed with NeverDeallocate
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (EagerDeallocate)":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[8, int](manager, EagerDeallocate)

    # Push items to create segments
    var p = queue.getProducer()
    for i in 1..1000:
      p.push(i)

    # Pop all items
    for i in 1..1000:
      discard queue.pop()

    # Segments SHOULD be freed with EagerDeallocate
    check(queue.segmentCount() <= 3)
