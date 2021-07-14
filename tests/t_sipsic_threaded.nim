# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import options
import unittest

import lockfreequeues

const capacity = 8
const itemCount = 128

var
  queue = initSipsic[capacity, int]()
  output = initSipsic[itemCount, int]()


proc consumerFunc() {.thread.} =
  var count = 0
  while count < itemCount:
    let res = queue.pop()
    if res.isSome:
      while not output.push(res.get):
        discard
      inc count


proc producerFunc() {.thread.} =
  for i in 0..<itemCount:
    while not queue.push(i):
      discard


suite "Sipsic[N, T] threaded":

  test "basic":
    var
      consumer: Thread[void]
      producer: Thread[void]
      i = 0

    consumer.createThread(consumerFunc)
    producer.createThread(producerFunc)

    while i < itemCount:
      let msg = output.pop()
      if msg.isSome:
        require(msg.get == i)
        inc i

    joinThread(producer)
    joinThread(consumer)
