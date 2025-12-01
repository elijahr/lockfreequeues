# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_mupmuc


const
  ItemsPerProducer = 2500
  SegmentSize = 64
  ProducerCount = 4
  ConsumerCount = 4


type
  ProducerContext = object
    queue: ptr UnboundedMupmuc[SegmentSize, int]
    producersDone: ptr Atomic[int]
    producer: ptr Producer[SegmentSize, int]
    producerIdx: int

  ConsumerContext = object
    queue: ptr UnboundedMupmuc[SegmentSize, int]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]
    consumer: ptr Consumer[SegmentSize, int]


proc producer(ctx: ptr ProducerContext) {.thread, gcsafe.} =
  for i in 1..ItemsPerProducer:
    ctx.producer[].push(ctx.producerIdx * ItemsPerProducer + i)
  discard ctx.producersDone[].fetchAdd(1, moRelease)


proc consumer(ctx: ptr ConsumerContext) {.thread, gcsafe.} =
  let totalItems = ItemsPerProducer * ProducerCount
  while true:
    let item = ctx.consumer[].pop()
    if item.isSome:
      discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      # All producers done, check if queue is drained
      let item2 = ctx.consumer[].pop()
      if item2.isSome:
        discard ctx.totalConsumed[].fetchAdd(1, moRelaxed)
      elif ctx.totalConsumed[].load(moAcquire) >= totalItems:
        break


suite "UnboundedMupmuc threaded":

  test "multiple producers multiple consumers":
    let manager = newEpochManager()
    var queue = newUnboundedMupmuc[SegmentSize, int](manager)
    var producersDone: Atomic[int]
    var totalConsumed: Atomic[int]

    producersDone.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)

    # Pre-register all producers and consumers in main thread
    var producers: array[ProducerCount, Producer[SegmentSize, int]]
    var consumers: array[ConsumerCount, Consumer[SegmentSize, int]]
    for i in 0..<ProducerCount:
      producers[i] = queue.getProducer()
    for i in 0..<ConsumerCount:
      consumers[i] = queue.getConsumer()

    # Create producer contexts
    var prodContexts: array[ProducerCount, ProducerContext]
    for i in 0..<ProducerCount:
      prodContexts[i] = ProducerContext(
        queue: addr queue,
        producersDone: addr producersDone,
        producer: addr producers[i],
        producerIdx: i
      )

    # Create consumer contexts
    var consContexts: array[ConsumerCount, ConsumerContext]
    for i in 0..<ConsumerCount:
      consContexts[i] = ConsumerContext(
        queue: addr queue,
        producersDone: addr producersDone,
        totalConsumed: addr totalConsumed,
        consumer: addr consumers[i]
      )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext]]
    var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext]]

    for i in 0..<ProducerCount:
      createThread(prodThreads[i], producer, addr prodContexts[i])
    for i in 0..<ConsumerCount:
      createThread(consThreads[i], consumer, addr consContexts[i])

    for i in 0..<ProducerCount:
      joinThread(prodThreads[i])
    for i in 0..<ConsumerCount:
      joinThread(consThreads[i])

    check(totalConsumed.load(moAcquire) == ItemsPerProducer * ProducerCount)
