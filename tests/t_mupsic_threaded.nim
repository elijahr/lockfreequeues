# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import algorithm
import atomics
import options
import sequtils
import unittest

import lockfreequeues


const capacity = 8
const producerCount = 32

var
  counter: Atomic[int]
  queue = initMupsic[capacity, producerCount, int]()
  output = initSipsic[producerCount, int]()
  consumerThread: Thread[void]
  producerThreads: array[producerCount, Thread[void]]


proc consumerFunc() {.thread.} =
  for idx in 0..<producerCount:
    while true:
      if idx mod 2 == 0:
        var items = queue.pop(1)
        if items.isSome:
          while not output.push(items.get[0]):
            discard
          break
      else:
        var item = queue.pop()
        if item.isSome:
          while not output.push(item.get):
            discard
          break


proc producerFunc() {.thread.} =
  var producer = queue.getProducer()
  let p = counter.fetchAdd(1)
  while true:
    if p mod 2 == 0:
      if producer.push(p):
        break
    else:
      if producer.push(@[p]).isNone:
        break


suite "Mupmuc[N, P, C, T] threaded":

  test "basic":
    consumerThread.createThread(consumerFunc)

    for p in 0..<producerCount:
      producerThreads[p].createThread(producerFunc)

    joinThreads(producerThreads)
    joinThread(consumerThread)

    var received = newSeq[int]()
    while received.len < producerCount:
      let msg = output.pop()
      if msg.isSome:
        received.add(msg.get)

    received.sort()

    check(received == (0..<producerCount).toSeq)
