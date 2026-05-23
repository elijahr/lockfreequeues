## UnboundedSipsic threaded stress — currently disabled in stress_test.nim
## (see the comment block there). Kept on disk so that re-enabling is a
## one-line change. Post-3.3.11-B.2.5 the standalone
## `UnboundedSipsic[S, T]` was absorbed into
## `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`.

import options
import unittest2

import lockfreequeues/atomic_dsl
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub


const
  ItemCount = 10000
  MT = 4
    ## Type-uniform MaxThreads phantom for the sipsic-absorbed branch.


type
  SipsicQ[S: static int] =
    Queue[int, ccSingle, ccSingle, stEager, S, MT]

  TestContext[S: static int] = object
    queue: ptr SipsicQ[S]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]


proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var p = ctx.queue[].getProducer()
  for i in 1..ItemCount:
    p.push(i)
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
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()
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
    var queue = newUnboundedSipsicQueue[int, stEager, 64, MT]()
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

  test "segment retirement after drain":
    # Sipsic deallocates segments inline (no manager). After draining
    # the queue, segment count should be small (only the active tail).
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()
    var p = queue.getProducer()

    # Push items to create segments
    for i in 1..1000:
      p.push(i)

    # Pop all items
    for i in 1..1000:
      discard queue.pop()

    # Segments should be freed inline.
    check(queue.segmentCount() <= 3)
