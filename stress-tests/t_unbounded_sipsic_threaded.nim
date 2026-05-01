import options
import unittest2

import lockfreequeues/unbounded_sipsic


const ItemCount = 10000


type
  TestContext[S: static int] = object
    queue: ptr UnboundedSipsic[S, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]


proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  for i in 1..ItemCount:
    ctx.queue[].push(i)
  ctx.producerDone[].store(true, moRelease)


proc consumer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      # Producer done but we haven't consumed everything - keep trying
      discard


suite "UnboundedSipsic threaded":

  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]

  setup:
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)

  test "high segment turnover":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager)
    var ctx = TestContext[8](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone
    )

    var prodThread, consThread: Thread[ptr TestContext[8]]
    createThread(prodThread, producer[8], addr ctx)
    createThread(consThread, consumer[8], addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0..<ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[64, int](manager)
    var ctx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone
    )

    var prodThread, consThread: Thread[ptr TestContext[64]]
    createThread(prodThread, producer[64], addr ctx)
    createThread(consThread, consumer[64], addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0..<ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement (Manual)":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager, Manual)

    # Push items to create segments
    for i in 1..1000:
      queue.push(i)
    let peakSegments = queue.segmentCount()

    # Pop all items
    for i in 1..1000:
      discard queue.pop()

    # Segments should NOT be freed with Manual
    check(queue.segmentCount() == peakSegments)

  test "segment retirement (Eager)":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager, Eager)

    # Push items to create segments
    for i in 1..1000:
      queue.push(i)

    # Pop all items
    for i in 1..1000:
      discard queue.pop()

    # Segments SHOULD be freed with Eager
    check(queue.segmentCount() <= 3)
