# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.


template testMupGetProducerAssigns*(queue: untyped) =
  let producer = queue.getProducer()
  check(producer.idx == 0)
  check(queue.producerThreadIds[0].acquire == getThreadId())
  for p in 1..<queue.producerCount:
    check(queue.producerThreadIds[p].acquire == 0)


template testMupGetProducerReusesAssigned*(queue: untyped) =
  discard queue.getProducer()
  let producer = queue.getProducer()
  check(producer.idx == 0)
  check(queue.producerThreadIds[0].acquire == getThreadId())
  for p in 1..<queue.producerCount:
    check(queue.producerThreadIds[p].acquire == 0)


template testMupGetProducerExplicitIndex*(queue: untyped) =
  for idx in 0..<queue.producerCount:
    check(queue.getProducer(idx).idx == idx)


template testMupGetProducerThrowsNoProducersAvailable*(queue: untyped) =
  proc assignProducer() {.thread.} = discard queue.getProducer()
  var threads: array[4, Thread[void]]
  for i in 0..3:
    threads[i].createThread(assignProducer)
  joinThreads(threads)
  expect NoProducersAvailableDefect:
    discard queue.getProducer()


template testMupPush*(queue: untyped) =
  check(queue.getProducer(0).push(1) == true)
  check(queue.getProducer(0).push(2) == true)
  queue.checkState(
    head=0,
    tail=2,
    storage=(@[1, 2, 0, 0, 0, 0, 0, 0]),
  )
  queue.checkState(
    prevProducerIdx=0,
    producerTails=(@[2, 0, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )

  check(queue.getProducer(1).push(3) == true)
  check(queue.getProducer(1).push(4) == true)

  queue.checkState(
    head=0,
    tail=4,
    storage=(@[1, 2, 3, 4, 0, 0, 0, 0]),
  )
  queue.checkState(
    prevProducerIdx=1,
    producerTails=(@[2, 4, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )

  check(queue.getProducer(2).push(5) == true)
  check(queue.getProducer(2).push(6) == true)

  queue.checkState(
    head=0,
    tail=6,
    storage=(@[1, 2, 3, 4, 5, 6, 0, 0]),
  )
  queue.checkState(
    prevProducerIdx=2,
    producerTails=(@[2, 4, 6, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )

  check(queue.getProducer(3).push(7) == true)
  check(queue.getProducer(3).push(8) == true)

  queue.checkState(
    head=0,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx=3,
    producerTails=(@[2, 4, 6, 8]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )


template testMupPushOverflow*(queue: untyped) =
  for i in 1..8:
    discard queue.getProducer(0).push(i)
  check(queue.getProducer(0).push(9) == false)
  queue.checkState(
    head=0,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx=0,
    producerTails=(@[8, 0, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )

template testMupPushWrap*(queue: untyped) =
  for i in 1..4:
    discard queue.getProducer(0).push(i)
  for i in 0..1:
    when queue is Mupmuc:
      discard queue.getConsumer(i).pop()
    else:
      discard queue.pop()
  for i in 5..10:
    check(queue.getProducer(0).push(i) == true)
  queue.checkState(
    head=2,
    tail=10,
    storage=(@[9, 10, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx=0,
    producerTails=(@[10, 0, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=1,
      consumerHeads=(@[1, 2, 0, 0]),
    )


template testMupPushSeq*(queue: untyped) =
  check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  queue.checkState(
    head=0,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx=0,
    producerTails=(@[8, 0, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )


template testMupPushSeqOverflow*(queue: untyped) =
  let res = queue.getProducer(0).push(
    @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  )
  check(res.isSome)
  check(res.get == 8..15)
  queue.checkState(
    head=0,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx=0,
    producerTails=(@[8, 0, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=NoConsumerIdx,
      consumerHeads=repeat(0, 4),
    )

template testMupPushSeqWrap*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4])
  for i in 0..1:
    when queue is Mupmuc:
      discard queue.getConsumer(i).pop()
    else:
      discard queue.pop()
  var res = queue.getProducer(0).push(@[5, 6, 7, 8, 9, 10])
  check(res.isNone)
  queue.checkState(
    head=2,
    tail=10,
    storage=(@[9, 10, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx=0,
    producerTails=(@[10, 0, 0, 0]),
  )
  when queue is Mupmuc:
    queue.checkState(
      prevConsumerIdx=1,
      consumerHeads=(@[1, 2, 0, 0]),
    )
