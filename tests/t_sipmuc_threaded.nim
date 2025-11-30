# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import algorithm
import atomics
import options
import sequtils
import unittest2

import lockfreequeues


const
  capacity = 16
  consumerCount = 4
  itemCount = 16


var
  queue = initSipmuc[capacity, consumerCount, int]()
  output = initMupmuc[itemCount, consumerCount, 1, int]()
  consumerThreads: array[consumerCount, Thread[void]]
  totalProcessed: Atomic[int]
  producerDone: Atomic[bool]


proc consumerFunc() {.thread.} =
  var consumer = queue.getConsumer()
  var outputProducer = output.getProducer()

  while true:
    var item = consumer.pop()
    if item.isSome:
      while not outputProducer.push(item.get):
        discard
      discard totalProcessed.fetchAdd(1, moRelaxed)
    elif producerDone.load(moAcquire) and totalProcessed.load(moRelaxed) >= itemCount:
      break


suite "Sipmuc threaded":

  test "single producer, multiple consumers":
    # Reset
    totalProcessed.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)

    var outputConsumer = output.getConsumer()

    # Start consumer threads
    for c in 0..<consumerCount:
      consumerThreads[c].createThread(consumerFunc)

    # Producer pushes items (main thread)
    for i in 1..itemCount:
      while not queue.push(i):
        discard

    producerDone.store(true, moRelease)

    # Collect output
    var received = newSeq[int]()
    while received.len < itemCount:
      var item = outputConsumer.pop()
      if item.isSome:
        received.add(item.get)

    joinThreads(consumerThreads)

    received.sort()

    check(received == (1..itemCount).toSeq)
    check(totalProcessed.load(moRelaxed) == itemCount)
