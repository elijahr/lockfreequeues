# SPSCQueueStatic
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer, lock-free, wait-free queue.
##
## Based on the algorithm outlined by Juho Snellman at
## https://www.snellman.net/blog/archive/2016-12-13-ring-queues/

import options
import os
import unittest

import lockfreequeues/spscqueuestatic
import ./testdefs


suite "SPSCQueueStatic: initialization":

  test "newSPSCQueue[N, T]()":
    var queue = newSPSCQueue[8, int]()
    require(queue.state == (
      head: 0u,
      tail: 0u,
      storage: @[0, 0, 0, 0, 0, 0, 0, 0]
    ))

  test "newSPSCQueue[N, T]() without power of 2 throws ValueError":
    expect(ValueError):
      discard newSPSCQueue[1, int]()
    expect(ValueError):
      discard newSPSCQueue[3, int]()
    expect(ValueError):
      discard newSPSCQueue[13, int]()

  test "reset()":
    var queue = newSPSCQueue[8, int]()
    testReset(queue)


suite "SPSCQueueStatic: operations":
  var queue = newSPSCQueue[8, int]()

  setup:
    queue.reset()

  test "push()":
    testPush(queue)

  test "push() overflow":
    testPushOverflow(queue)

  test "push() wrap":
    testPushWrap(queue)

  test "pop() one":
    testPopOne(queue)

  test "pop() all":
    testPopAll(queue)

  test "pop() empty":
    testPopEmpty(queue)

  test "pop() too many":
    testPopTooMany(queue)

  test "pop() wrap":
    testPopWrap(queue)

  test "capacity":
    testCapacity(queue)

  test "head and tail reset to 0 on uint overflow":
    testResets(queue)

  test "wraps":
    testWraps(queue)


var channel: Channel[int]


proc consumerFunc(q: pointer) {.thread.} =
  let queuePtr = cast[ptr SPSCQueueStatic[8, int]](q)
  var count = 0
  while count < 128:
    var res = queuePtr[].pop(1)
    if res.isSome:
      let msg = res.get()[0]
      channel.send(msg)
      count += 1
    else:
      sleep(11)


proc producerFunc(q: pointer) {.thread.} =
  let queuePtr = cast[ptr SPSCQueueStatic[8, int]](q)
  for i in 1..128:
    while queuePtr[].push(@[i]).isSome:
      sleep(10)


suite "SPSCQueueStatic: threaded":
  var
    queue = newSPSCQueue[8, int]()
    consumer: Thread[pointer]
    producer: Thread[pointer]

  setup:
    queue.reset()
    channel.open()
    consumer.createThread(consumerFunc, addr(queue))
    producer.createThread(producerFunc, addr(queue))

  teardown:
    joinThreads(consumer, producer)
    channel.close()

  test "works":
    for i in 1..128:
      check(channel.recv() == i)
