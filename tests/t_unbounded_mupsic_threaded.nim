# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_mupsic


const
  ItemsPerProducer = 2500
  SegmentSize = 64
  ProducerCount = 4


type
  TestContext = object
    queue: ptr UnboundedMupsic[SegmentSize, int]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]
    producerIdx: int


proc producer(ctx: ptr TestContext) {.thread, gcsafe.} =
  var myProducer = ctx.queue[].getProducer()
  for i in 1..ItemsPerProducer:
    myProducer.push(ctx.producerIdx * ItemsPerProducer + i)
  discard ctx.producersDone[].fetchAdd(1, moRelease)


proc consumer(ctx: ptr TestContext) {.thread, gcsafe.} =
  var consumed = 0
  let totalItems = ItemsPerProducer * ProducerCount
  while true:
    let item = ctx.queue[].pop()
    if item.isSome:
      discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
      inc consumed
      if consumed >= totalItems:
        break
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      # All producers done, drain remaining
      let item2 = ctx.queue[].pop()
      if item2.isSome:
        discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
        inc consumed
      elif consumed >= totalItems:
        break
      else:
        # Might be gaps due to timing, check total
        if ctx.totalConsumed[].load(moAcquire) >= totalItems:
          break


suite "UnboundedMupsic threaded":

  test "multiple producers single consumer":
    let manager = newEpochManager()
    var queue = newUnboundedMupsic[SegmentSize, int](manager)
    var producersDone: Atomic[int]
    var totalConsumed: Atomic[int]

    producersDone.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)

    var baseCtx = TestContext(
      queue: addr queue,
      producersDone: addr producersDone,
      totalConsumed: addr totalConsumed,
      producerIdx: 0
    )

    # Create per-producer contexts
    var contexts: array[ProducerCount, TestContext]
    for i in 0..<ProducerCount:
      contexts[i] = baseCtx
      contexts[i].producerIdx = i

    var prodThreads: array[ProducerCount, Thread[ptr TestContext]]
    var consThread: Thread[ptr TestContext]

    for i in 0..<ProducerCount:
      createThread(prodThreads[i], producer, addr contexts[i])
    createThread(consThread, consumer, addr baseCtx)

    for i in 0..<ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(totalConsumed.load(moAcquire) == ItemsPerProducer * ProducerCount)
