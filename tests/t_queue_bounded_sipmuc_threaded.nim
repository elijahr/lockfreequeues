## Renamed and migrated from `t_sipmuc_threaded.nim` — mechanical
## conversion to the unified Queue type. This file is DISABLED at the
## import site in `tests/test.nim` due to a pre-existing deadlock
## unrelated to the typestate / cardinality-collapse migration. The
## file body is still mechanically converted to keep it compiling
## against the new Queue API per impl plan B2.
##
## Mechanical conversion per Doc C 5:
##   ptr Sipmuc[N, C, int] -> ptr Queue[int, ccSingle, ccMulti, stEager,
##                                       rkNone, N, 0, C, 0, 0]
##   initSipmuc[N, C, int]() -> initQueue[int, ccSingle, ccMulti, stEager,
##                                          N, 0, C]()
##
## Test count parity: 2 tests (matches the legacy file).
## Track B / Task B2. Doc C 3.7, 5, 6.1.

import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues
import lockfreequeues/queue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

const
  ItemCount = 10000
  ConsumerCount = 4

type TestContext[N: static int] = object
  queue: ptr Queue[int, ccSingle, ccMulti, stEager, rkNone,
                    N, 0, ConsumerCount, 0, 0]
  received: ptr array[ItemCount, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producerDone: ptr Atomic[bool]
  totalConsumed: ptr Atomic[int]

proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  for i in 1 .. ItemCount:
    while not ctx.queue[].push(i):
      discard
  ctx.producerDone[].store(true, moRelease)

proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
        break
    elif ctx.producerDone[].load(moAcquire):
      if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
        break

suite "Queue SPMC threaded":
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

  test "high contention":
    var queue = q_mod.initQueue[int, ccSingle, ccMulti, stEager,
                                 16, 0, ConsumerCount]()
    var ctx = TestContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed,
    )

    var prodThread: Thread[ptr TestContext[16]]
    var consThreads: array[ConsumerCount, Thread[ptr TestContext[16]]]

    createThread(prodThread, producer[16], addr ctx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[16], addr ctx)

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal capacity":
    var queue = q_mod.initQueue[int, ccSingle, ccMulti, stEager,
                                 64, 0, ConsumerCount]()
    var ctx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed,
    )

    var prodThread: Thread[ptr TestContext[64]]
    var consThreads: array[ConsumerCount, Thread[ptr TestContext[64]]]

    createThread(prodThread, producer[64], addr ctx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], consumer[64], addr ctx)

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
