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

const capacity = 10
const producerCount = 4

var
  counters: array[queueCount, Atomic[int]]
  queues: array[queueCount, Mupsic[capacity, producerCount, int]]
  outputs: array[queueCount, Sipsic[producerCount, int]]
  consumerThreads: array[queueCount, Thread[int]]
  producerThreads: array[producerCount*queueCount, Thread[(int, int)]]


proc consumerFunc(queueIndex: int) {.thread.} =
  # var queue: ref Mupsic[10, 4, system.int]
  # queue[] = queues[queueIndex]
  # var output: ref Sipsic[4, system.int]
  # output[] = outputs[queueIndex]

  var sleepMs = 0
  for idx in 0..<producerCount:
    while true:
      sleep(sleepMs)
      if sleepMs >= 10:
        sleepMs = 0
      else:
        sleepMs += 2
      if idx mod 2 == 0:
        var items = queues[queueIndex].pop(1)
        if items.isSome:
          while not outputs[queueIndex].push(items.get[0]):
            discard
          break
      else:
        var item = queues[queueIndex].pop()
        if item.isSome:
          while not outputs[queueIndex].push(item.get):
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


proc testBasic(queueIndex, producerSleepMs: int) =
  counters[queueIndex].store(0)
  queues[queueIndex] = initMupsic[capacity, producerCount, int]()
  outputs[queueIndex] = initSipsic[producerCount, int]()

  consumerThreads[queueIndex].createThread(consumerFunc, queueIndex)

  for p in 0..<producerCount:
    producerThreads[(queueIndex * producerCount)+p].createThread(producerFunc, (queueIndex, producerSleepMs))


suite "Mupsic[N, P, T] threaded":

  test "basic":
    # Test with various produce/consume rhythms
    var queueIndex = 0
    for producerSleepMs in 0..<queueCount:
      testBasic(queueIndex, producerSleepMs)
      queueIndex += 1
    joinThreads(producerThreads)
    joinThreads(consumerThreads)

    for queueIndex in 0..<queueCount:
      var received = newSeq[int]()
      while received.len < producerCount:
        var item = outputs[queueIndex].pop()
        if item.isSome:
          received.add(item.get)
      received.sort()
      check(received == (0..<producerCount).toSeq)



