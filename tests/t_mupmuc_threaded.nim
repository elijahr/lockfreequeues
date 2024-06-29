# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import algorithm
import atomics
import math
import options
import os
import sequtils
import unittest

import lockfreequeues

const queueCount = 100

# queueCount must be a perfect square
assert(sqrt(float(queueCount)) == ceil(sqrt(float(queueCount))), "queueCount must be a perfect square")

const capacity = 1000
const workerCount = 31

var
  counters: array[queueCount, Atomic[int]]
  queues: array[queueCount, Mupmuc[capacity, workerCount, workerCount, int]]
  outputs: array[queueCount, Mupmuc[workerCount, workerCount, 1, int]]
  consumerThreads: array[workerCount*queueCount, Thread[(int, int)]]
  producerThreads: array[workerCount*queueCount, Thread[(int, int)]]


proc consumerFunc(args: tuple[queueIndex: int, sleepMs: int]) {.thread.} =
  var consumer = queues[args.queueIndex].getConsumer()
  var outputProducer = outputs[args.queueIndex].getProducer()
  while true:
    sleep(args.sleepMs)
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


proc producerFunc(args: tuple[queueIndex: int, sleepMs: int]) {.thread.} =
  var producer = queues[args.queueIndex].getProducer()
  let p = counters[args.queueIndex].fetchAdd(1)
  while true:
    sleep(args.sleepMs)
    if p mod 2 == 0:
      if producer.push(p):
        break
    else:
      if producer.push(@[p]).isNone:
        break


proc testBasic(queueIndex, consumerSleepMs, producerSleepMs: int) =
  counters[queueIndex].store(0)
  queues[queueIndex] = initMupmuc[capacity, workerCount, workerCount, int]()
  outputs[queueIndex] = initMupmuc[workerCount, workerCount, 1, int]()

  for c in 0..<workerCount:
    consumerThreads[(queueIndex * workerCount)+c].createThread(consumerFunc, (queueIndex, consumerSleepMs))

  for p in 0..<workerCount:
    producerThreads[(queueIndex * workerCount)+p].createThread(producerFunc, (queueIndex, producerSleepMs))


suite "Mupmuc[N, P, C, T] threaded":

  test "basic":
    # Test with various produce/consume rhythms
    var queueIndex = 0
    for consumerSleepMs in 0..<int(sqrt(float(queueCount))):
      for producerSleepMs in 0..<int(sqrt(float(queueCount))):
        testBasic(queueIndex, consumerSleepMs, producerSleepMs)
        queueIndex += 1

    joinThreads(producerThreads)
    joinThreads(consumerThreads)

    for queueIndex in 0..<queueCount:
      var outputConsumer = outputs[queueIndex].getConsumer()
      var received = newSeq[int]()
      while received.len < workerCount:
        var item = outputConsumer.pop()
        if item.isSome:
          received.add(item.get)
      received.sort()
      check(received == (0..<workerCount).toSeq)



