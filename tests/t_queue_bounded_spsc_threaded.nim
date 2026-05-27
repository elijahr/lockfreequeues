## Migrated from `t_spsc_threaded.nim` — single-producer, single-
## consumer concurrent test for the unified Queue under SPSC
## cardinality.
##
## Mechanical conversion per Doc C 5:
##   ptr Spsc[N, int] -> ptr Queue[int, ccSingle, ccSingle, stEager,
##                                    rkNone, N, 0, 0, 0, 0]
##   initSpsc[N, int]() -> newBQueue[int, ccSingle, ccSingle, ##                                      N, 0, 0]()
##
## Test count parity: 2 tests (matches t_spsc_threaded.nim).
## Track B / Task B2. Doc C 3.7, 5, 6.1.

import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

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
      let val = item.get - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      discard

suite "Queue SPSC threaded":
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
    var queue = q_mod.newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
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
    var queue = q_mod.newBQueue[int, ccSingle, ccSingle, 64, 0, 0]()
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
