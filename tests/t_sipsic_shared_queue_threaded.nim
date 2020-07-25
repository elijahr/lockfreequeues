# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import options
import os
import unittest

import lockfreequeues


var channel: Channel[int]


proc consumerFunc(queue: ref SipsicSharedQueue[int]) {.thread.} =
  var count = 0
  while count < 128:
    var res = queue.pop(1)
    if res.isSome:
      let msg = res.get()[0]
      channel.send(msg)
      inc count
    else:
      sleep(11)


proc producerFunc(queue: ref SipsicSharedQueue[int]) {.thread.} =
  for i in 1..128:
    while queue.push(@[i]).isSome:
      sleep(10)


suite "SipsicSharedQueue[T] threaded":

  test "basic":
    var
      queue: ref SipsicSharedQueue[int] = newSipsicQueue[int](8)
      consumer: Thread[ref SipsicSharedQueue[int]]
      producer: Thread[ref SipsicSharedQueue[int]]
    channel.open()
    consumer.createThread(consumerFunc, queue)
    producer.createThread(producerFunc, queue)
    for i in 1..128:
      require(channel.recv() == i)
    joinThreads(consumer, producer)
    channel.close()

