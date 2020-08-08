# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import algorithm
import atomics
import options
import os
import sequtils
import unittest

import lockfreequeues


const producerCount = 100
const consumerCount = 50

var
  channel: Channel[int]
  queue = initMupmuc[8, producerCount, consumerCount, int]()
  counter: Atomic[int]


proc consumerFunc() {.thread.} =
  var consumer = queue.getConsumer()
  while counter.sequential < producerCount:
    sleep(11)
    if consumer.idx mod 2 == 0:
      var items: Option[seq[int]] = consumer.pop(1)
      if items.isSome:
        channel.send(items.get[0])
        counter += 1
    else:
      var item: Option[int] = consumer.pop()
      if item.isSome:
        channel.send(item.get)
        counter += 1


proc producerFunc(p: int) {.thread.} =
  var producer = queue.getProducer()
  while true:
    sleep(10)
    if p mod 2 == 0:
      if producer.push(p):
        break
    else:
      if producer.push(@[p]).isNone:
        break


suite "Mupmuc[N, P, C, T] threaded":

  test "basic":
    var
      consumerThreads: array[consumerCount, Thread[void]]
      producerThreads: array[producerCount, Thread[int]]

    channel.open()
    for c in 0..<consumerCount:
      consumerThreads[c].createThread(consumerFunc)
    for p in 0..<producerCount:
      producerThreads[p].createThread(producerFunc, p)
    var received = newSeq[int]()
    for i in 0..<producerCount:
      received.add(channel.recv())
    joinThreads(producerThreads)
    joinThreads(consumerThreads)
    channel.close()
    received.sort()
    check(received == (0..<producerCount).toSeq)
