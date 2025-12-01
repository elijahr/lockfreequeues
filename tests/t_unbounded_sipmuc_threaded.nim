# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_sipmuc


const
  ItemCount = 10000
  SegmentSize = 64
  ConsumerCount = 4


type
  TestContext = object
    queue: ptr UnboundedSipmuc[SegmentSize, int]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]


proc producer(ctx: ptr TestContext) {.thread, gcsafe.} =
  for i in 1..ItemCount:
    ctx.queue[].push(i)
  ctx.producerDone[].store(true, moRelease)


proc consumer(ctx: ptr TestContext) {.thread, gcsafe.} =
  var myConsumer = ctx.queue[].getConsumer()
  var consumed = 0
  while true:
    let item = myConsumer.pop()
    if item.isSome:
      discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      # Double-check after seeing producer done
      let item2 = myConsumer.pop()
      if item2.isSome:
        discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
        inc consumed
      else:
        # Check if all items consumed globally
        if ctx.totalConsumed[].load(moAcquire) >= ItemCount:
          break
    # Yield to other threads
    if consumed mod 100 == 0:
      discard


suite "UnboundedSipmuc threaded":

  test "single producer multiple consumers":
    let manager = newEpochManager()
    var queue = newUnboundedSipmuc[SegmentSize, int](manager)
    var producerDone: Atomic[bool]
    var totalConsumed: Atomic[int]

    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

    var ctx = TestContext(
      queue: addr queue,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed
    )

    var prodThread: Thread[ptr TestContext]
    var consThreads: array[ConsumerCount, Thread[ptr TestContext]]

    createThread(prodThread, producer, addr ctx)
    for i in 0..<ConsumerCount:
      createThread(consThreads[i], consumer, addr ctx)

    joinThread(prodThread)
    for i in 0..<ConsumerCount:
      joinThread(consThreads[i])

    check(totalConsumed.load(moAcquire) == ItemCount)
