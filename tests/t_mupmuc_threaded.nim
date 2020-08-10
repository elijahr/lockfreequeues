# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import algorithm
import options
import sequtils
import threadpool
import unittest

import lockfreequeues


const producerCount = MaxDistinguishedThread
const consumerCount = MaxDistinguishedThread

var
  channel: Channel[int]
  queue = initMupmuc[8, producerCount, consumerCount, int]()
  consumerThreads: array[consumerCount, Thread[void]]
  producerThreads: array[producerCount, Thread[int]]


proc consumerFunc() {.thread.} =
  var consumer = queue.getConsumer()
  while true:
    if consumer.idx mod 2 == 0:
      var items = consumer.pop(1)
      if items.isSome:
        channel.send(items.get[0])
        break
    else:
      var item = consumer.pop()
      if item.isSome:
        channel.send(item.get)
        break


proc producerFunc(p: int) {.thread.} =
  var producer = queue.getProducer()
  while true:
    if p mod 2 == 0:
      if producer.push(p):
        break
    else:
      if producer.push(@[p]).isNone:
        break


suite "Mupmuc[N, P, C, T] threaded":

  channel.open()

  test "basic":
    for i in 1..25:
      queue.reset()

      for c in 0..<consumerCount:
        consumerThreads[c].createThread(consumerFunc)

      for p in 0..<producerCount:
        producerThreads[p].createThread(producerFunc, p)

      var received = newSeq[int]()
      for i in 0..<producerCount:
        received.add(channel.recv())

      joinThreads(producerThreads)
      joinThreads(consumerThreads)

      received.sort()

      check(received == (0..<producerCount).toSeq)

  channel.close()
