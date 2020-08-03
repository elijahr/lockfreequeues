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


proc producerFunc(pid: int) {.thread.} =
  while true:
    if pid mod 2 == 0:
      if queue.push(pid, pid):
        break
    else:
      if queue.push(pid, @[pid]).isNone:
        break


suite "Mupsic[N, P, T] threaded":

  test "basic":
    var
      consumer: Thread[void]
      producers: array[producerCount, Thread[int]]

    channel.open()
    consumer.createThread(consumerFunc)
    for i in 0..<producerCount:
      producers[i].createThread(producerFunc, i)
    var received = newSeq[int]()
    for i in 0..<producerCount:
      received.add(channel.recv())
    joinThread(consumer)
    joinThreads(producers)
    channel.close()
    received.sort()
    check(received == (0..<producerCount).toSeq)
