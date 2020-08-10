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

var
  channel: Channel[int]
  queue = initMupsic[8, producerCount, int]()
  consumerThread: Thread[void]
  producerThreads: array[producerCount, Thread[int]]


proc consumerFunc() {.thread.} =
  for idx in 0..<producerCount:
    while true:
      if idx mod 2 == 0:
        var items = queue.pop(1)
        if items.isSome:
          channel.send(items.get[0])
          break
      else:
        var item = queue.pop()
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

      consumerThread.createThread(consumerFunc)

      for p in 0..<producerCount:
        producerThreads[p].createThread(producerFunc, p)

      var received = newSeq[int]()
      for i in 0..<producerCount:
        received.add(channel.recv())

      joinThreads(producerThreads)
      joinThread(consumerThread)

      received.sort()

      check(received == (0..<producerCount).toSeq)

  channel.close()
