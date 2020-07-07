# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import options
import os
import unittest

import lockfreequeues/spsc/sharedqueue


var channel: Channel[int]


proc consumerFunc(q: pointer) {.thread.} =
  let queuePtr = cast[ptr SharedQueue[int]](q)
  var count = 0
  while count < 128:
    var res = queuePtr[].pop(1)
    if res.isSome:
      let msg = res.get()[0]
      channel.send(msg)
      inc count
    else:
      sleep(11)


proc producerFunc(q: pointer) {.thread.} =
  let queuePtr = cast[ptr SharedQueue[int]](q)
  for i in 1..128:
    while queuePtr[].push(@[i]).isSome:
      sleep(10)


suite "SharedQueue[T] threaded":

  test "basic":
    var
      queue = newSPSCQueue[int](8)
      consumer: Thread[pointer]
      producer: Thread[pointer]
    channel.open()
    consumer.createThread(consumerFunc, addr(queue))
    producer.createThread(producerFunc, addr(queue))
    for i in 1..128:
      require(channel.recv() == i)
    joinThreads(consumer, producer)
    channel.close()

