# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import algorithm
import options
import sequtils
import unittest

import lockfreequeues


const producerCount = 100

var
  channel: Channel[int]
  queue = initMupsic[8, producerCount, int]()


proc consumerFunc() {.thread.} =
  var count = 0
  while count < producerCount:
    var res: Option[int]
    res = queue.pop()
    if res.isSome:
      let msg = res.get
      channel.send(msg)
      inc count


proc producerFunc(i: int) {.thread.} =
  var producer = queue.getProducer()
  while true:
    if i mod 2 == 0:
      if producer.push(i):
        break
    else:
      if producer.push(@[i]).isNone:
        break


suite "Mupsic[N, P, T] threaded":

  test "basic":
    var
      consumer: Thread[void]
      producerThreads: array[producerCount, Thread[int]]

    channel.open()
    consumer.createThread(consumerFunc)
    for i in 0..<producerCount:
      producerThreads[i].createThread(producerFunc, i)
    var received = newSeq[int]()
    for i in 0..<producerCount:
      received.add(channel.recv())
    joinThread(consumer)
    joinThreads(producerThreads)
    channel.close()
    received.sort()
    check(received == (0..<producerCount).toSeq)
