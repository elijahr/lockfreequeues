## UnboundedSpsc threaded tests — post-3.3.11-B.2.5 the standalone
## `UnboundedSpsc[S, T]` is absorbed into
## `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`.

import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub

const
  ItemCount = 10000
  MT = 4
    ## Type-uniform MaxThreads phantom for the spsc-absorbed branch.

type
  SpscQ[S: static int] =
    Queue[int, ccSingle, ccSingle, stEager, S, MT]

  TestContext[S: static int] = object
    queue: ptr SpscQ[S]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]

proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var p = ctx.queue[].getProducer()
  for i in 1 .. ItemCount:
    p.push(i)
  ctx.producerDone[].store(true, moRelease)

proc consumer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1 # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      # Producer done but we haven't consumed everything - keep trying
      discard

suite "UnboundedSpsc threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)

  test "high segment turnover":
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()
    var ctx = TestContext[8](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
    )

    var prodThread, consThread: Thread[ptr TestContext[8]]
    createThread(prodThread, producer[8], addr ctx)
    createThread(consThread, consumer[8], addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal segment size":
    var queue = newUnboundedSpscQueue[int, stEager, 64, MT]()
    var ctx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
    )

    var prodThread, consThread: Thread[ptr TestContext[64]]
    createThread(prodThread, producer[64], addr ctx)
    createThread(consThread, consumer[64], addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "segment retirement bounded after drain":
    # Spsc deallocates segments inline (no strategy). After draining
    # the queue, segment count should be small (only the active tail segment).
    var queue = newUnboundedSpscQueue[int, stEager, 8, MT]()
    var p = queue.getProducer()

    # Push items to create segments
    for i in 1 .. 1000:
      p.push(i)

    # Pop all items
    for i in 1 .. 1000:
      discard queue.pop()

    # Segments should have been freed inline
    check(queue.segmentCount() <= 3)
