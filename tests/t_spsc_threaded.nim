import debra/atomics
import debra/atomics/dsl
import options
import unittest2

import lockfreequeues

const ItemCount = 10000

type TestContext[N: static int] = object
  queue: ptr BQueue[int, ccSingle, ccSingle, N, 0, 0]
  received: ptr array[ItemCount, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producerDone: ptr Atomic[bool]

proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  for i in 1 .. ItemCount:
    while not ctx.queue[].push(i):
      discard
  ctx.producerDone[].store(true, moRelease)

proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
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

suite "Spsc threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)

  test "high contention":
    var queue = newSpscQueue[int, 16]()
    var ctx = TestContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
    )

    var prodThread, consThread: Thread[ptr TestContext[16]]
    createThread(prodThread, producer[16], addr ctx)
    createThread(consThread, consumer[16], addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal capacity":
    var queue = newSpscQueue[int, 64]()
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
