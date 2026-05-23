import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues

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
      # All producers done but we haven't consumed everything - keep trying
      discard

suite "Mupsic threaded":
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
    var queue = newMupsicQueue[int, 16, ProducerCount]()

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
    var queue = newMupsicQueue[int, 64, ProducerCount]()

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
