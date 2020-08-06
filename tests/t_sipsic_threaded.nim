# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import options
import unittest

import lockfreequeues


var
  channel: Channel[int]
  queue = initSipsic[8, int]()


proc consumerFunc() {.thread.} =
  var count = 0
  while count < 128:
    let res = queue.pop()
    if res.isSome:
      let msg = res.get
      channel.send(msg)
      inc count
    else:
      cpuRelax()


proc producerFunc() {.thread.} =
  for i in 1..128:
    while not queue.push(i):
      cpuRelax()


suite "Sipsic[N, T] threaded":

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
