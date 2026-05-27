## Migrated from `t_mpsc_threaded.nim` — high-contention concurrent
## test for the unified Queue under MPSC cardinality.
##
## Mechanical conversion per Doc C 5:
##   ptr Mpsc[N, ProducerCount, int] -> ptr Queue[int, ccMulti, ccSingle,
##                                                    stEager, rkNone, N,
##                                                    ProducerCount, 0, 0, 0]
##   initMpsc[N, ProducerCount, int]() -> initQueue[int, ccMulti, ccSingle,
##                                                     stEager, N,
##                                                     ProducerCount, 0]()
##
## Test count parity: 2 tests (matches t_mpsc_threaded.nim).
## 7, 5, 6.1.

import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount

type TestContext[N: static int] = object
  queue: ptr BQueue[int, ccMulti, ccSingle, N, ProducerCount, 0]
  received: ptr array[ItemCount, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producersDone: ptr Atomic[int]
  producerIdx: int

proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1 .. ItemsPerProducer:
    while not p.push(base + i):
      discard
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1 # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      discard

suite "Queue MPSC threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)

  test "high contention":
    var queue = q_mod.newBQueue[int, ccMulti, ccSingle, 16, ProducerCount, 0]()

    var contexts: array[ProducerCount, TestContext[16]]
    for i in 0 ..< ProducerCount:
      contexts[i] = TestContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = TestContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0,
    )

    var prodThreads: array[ProducerCount, Thread[ptr TestContext[16]]]
    var consThread: Thread[ptr TestContext[16]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[16], addr contexts[i])
    createThread(consThread, consumer[16], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal capacity":
    var queue = q_mod.newBQueue[int, ccMulti, ccSingle, 64, ProducerCount, 0]()

    var contexts: array[ProducerCount, TestContext[64]]
    for i in 0 ..< ProducerCount:
      contexts[i] = TestContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0,
    )

    var prodThreads: array[ProducerCount, Thread[ptr TestContext[64]]]
    var consThread: Thread[ptr TestContext[64]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[64], addr contexts[i])
    createThread(consThread, consumer[64], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
