# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import options
import os
import unittest

import lockfreequeues/spsc/staticqueue


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


suite "StaticQueue[N, T] threaded":

  test "basic":
    var
      consumer: Thread[void]
      producer: Thread[void]
    channel.open()
    consumer.createThread(consumerFunc)
    producer.createThread(producerFunc)
    for i in 1..128:
      require(channel.recv() == i)
    joinThreads(consumer, producer)
    channel.close()
