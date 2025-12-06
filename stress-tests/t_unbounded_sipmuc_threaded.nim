# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_sipmuc


const
  ItemCount = 10000
  ConsumerCount = 4


type
  TestContext[S: static int] = object
    queue: ptr UnboundedSipmuc[S, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]


proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  for i in 1..ItemCount:
    ctx.queue[].push(i)
  ctx.producerDone[].store(true, moRelease)


proc consumer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
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
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

  test "high segment turnover":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager)
    var ctx = TestContext[8](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed
    )

    var prodThread: Thread[ptr TestContext[8]]
    var consThreads: array[ConsumerCount, Thread[ptr TestContext[8]]]

    createThread(prodThread, producer[8], addr ctx)
    for i in 0..<ConsumerCount:
      createThread(consThreads[i], consumer[8], addr ctx)

    joinThread(prodThread)
    for i in 0..<ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0..<ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[64, int](manager)
    var ctx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed
    )

    var prodThread: Thread[ptr TestContext[64]]
    var consThreads: array[ConsumerCount, Thread[ptr TestContext[64]]]

    createThread(prodThread, producer[64], addr ctx)
    for i in 0..<ConsumerCount:
      createThread(consThreads[i], consumer[64], addr ctx)

    joinThread(prodThread)
    for i in 0..<ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0..<ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager, Manual)

    # Push items to create segments
    for i in 1..1000:
      queue.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    var c = queue.getConsumer()
    for i in 1..1000:
      discard c.pop()

    # Segments should NOT be freed with Manual
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[8, int](manager, Eager)

    # Push items to create segments
    for i in 1..1000:
      queue.push(i)

    # Pop all items
    var c = queue.getConsumer()
    for i in 1..1000:
      discard c.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
