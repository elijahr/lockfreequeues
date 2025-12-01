# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_sipsic


const
  ItemCount = 10000
  SegmentSize = 64


type
  TestContext = object
    queue: ptr UnboundedSipsic[SegmentSize, int]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]


proc producer(ctx: ptr TestContext) {.thread, gcsafe.} =
  for i in 1..ItemCount:
    ctx.queue[].push(i)
  ctx.producerDone[].store(true, moRelease)


proc consumer(ctx: ptr TestContext) {.thread, gcsafe.} =
  var consumed = 0
  while true:
    let item = ctx.queue[].pop()
    if item.isSome:
      inc consumed
      if consumed >= ItemCount:
        break
    elif ctx.producerDone[].load(moAcquire):
      # Double-check after seeing producer done
      let item2 = ctx.queue[].pop()
      if item2.isSome:
        inc consumed
      if consumed >= ItemCount or item2.isNone:
        break
  ctx.totalConsumed[].store(consumed, moRelease)


suite "UnboundedSipsic threaded":

  test "concurrent producer and consumer":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[SegmentSize, int](manager)
    var producerDone: Atomic[bool]
    var totalConsumed: Atomic[int]

    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

    var ctx = TestContext(
      queue: addr queue,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed
    )

    var prodThread, consThread: Thread[ptr TestContext]
    createThread(prodThread, producer, addr ctx)
    createThread(consThread, consumer, addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(totalConsumed.load(moAcquire) == ItemCount)
    check(queue.len == 0)
