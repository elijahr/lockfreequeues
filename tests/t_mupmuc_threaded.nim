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
const workerCount = 16

var
  counter: Atomic[int]
  queue = initMupmuc[capacity, workerCount, workerCount, int]()
  output = initMupmuc[workerCount, workerCount, 1, int]()
  consumerThreads: array[workerCount, Thread[void]]
  producerThreads: array[workerCount, Thread[void]]


proc consumerFunc() {.thread.} =
  var consumer = queue.getConsumer()
  var outputProducer = output.getProducer()
  while true:
    if consumer.idx mod 2 == 0:
      var items = consumer.pop(1)
      if items.isSome:
        while not outputProducer.push(items.get[0]):
          discard
        break
    else:
      var item = consumer.pop()
      if item.isSome:
        while not outputProducer.push(item.get):
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


suite "Mupmuc[N, P, C, T] threaded (low capacity)":

  test "basic":
    var outputConsumer = output.getConsumer()

    for c in 0..<workerCount:
      consumerThreads[c].createThread(consumerFunc)

    for p in 0..<workerCount:
      producerThreads[p].createThread(producerFunc)

    var received = newSeq[int]()
    while received.len < workerCount:
      var item = outputConsumer.pop()
      if item.isSome:
        received.add(item.get)

    joinThreads(producerThreads)
    joinThreads(consumerThreads)

    received.sort()

    check(received == (0..<workerCount).toSeq)
