# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Single-producer, single-consumer, lock-free queue implementations for Nim.
##
## Based on the algorithm outlined by Juho Snellman at
## https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/

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

  test "push(int)":
    testPush(queue)

  test "push(int) overflow":
    testPushOverflow(queue)

  test "push(int) wrap":
    testPushWrap(queue)

  test "push(seq[T])":
    testPushSeq(queue)

  test "push(seq[T]) overflow":
    testPushSeqOverflow(queue)

  test "push(seq[T]) wrap":
    testPushSeqWrap(queue)

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

  test "pop(int) one":
    testPopCountOne(queue)

  test "pop(int) all":
    testPopCountAll(queue)

  test "pop(int) empty":
    testPopCountEmpty(queue)

  test "pop(int) too many":
    testPopCountTooMany(queue)

  test "pop(int) wrap":
    testPopCountWrap(queue)

  test "capacity":
    testCapacity(queue)

  test "head and tail reset to 0 on uint overflow":
    testResets(queue)

  test "wraps":
    testWraps(queue)


var
  channel: Channel[int]
  queue = newSPSCQueue[8, int]()


proc consumerFunc() {.thread.} =
  var count = 0
  while count < 128:
    var res = queue.pop(1)
    if res.isSome:
      let msg = res.get()[0]
      channel.send(msg)
      inc count
    else:
      sleep(11)


proc producerFunc() {.thread.} =
  for i in 1..128:
    while queue.push(@[i]).isSome:
      sleep(10)


suite "SPSCQueueStatic: threaded":
  var
    consumer: Thread[void]
    producer: Thread[void]

  setup:
    queue.reset()
    channel.open()
    consumer.createThread(consumerFunc)
    producer.createThread(producerFunc)

  teardown:
    joinThreads(consumer, producer)
    channel.close()

  test "works":
    for i in 1..128:
      check(channel.recv() == i)
