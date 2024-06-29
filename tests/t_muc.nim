# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.


template testMucPopOne*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  discard producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var consumer0 = queue.getConsumer(0)
  let res = consumer0.pop()
  check(res.isSome)
  check(res.get == 1)

  queue.checkState(
    head = 1,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 0,
    producerTails = (@[8, 0, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[1, 0, 0, 0]),
  )


template testMucPopAll*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  discard producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var consumer0 = queue.getConsumer(0)
  var items = newSeq[int]()
  for i in 1..8:
    let res = consumer0.pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 0,
    producerTails = (@[8, 0, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testMucPopEmpty*(queue: untyped) =
  var consumer0 = queue.getConsumer(0)
  check(consumer0.pop().isNone)

  queue.checkState(
    head = 0,
    tail = 0,
    storage = repeat(0, 8),
  )
  queue.checkState(
    prevProducerIdx = NoProducerIdx,
    producerTails = repeat(0, 4),
  )
  queue.checkState(
    prevConsumerIdx = NoConsumerIdx,
    consumerHeads = repeat(0, 4),
  )


template testMucPopTooMany*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  discard producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var consumer0 = queue.getConsumer(0)
  for i in 1..8:
    discard consumer0.pop()

  check(consumer0.pop().isNone)

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 0,
    producerTails = (@[8, 0, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testMucPopWrap*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  discard producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var consumer0 = queue.getConsumer(0)
  for i in 1..4:
    discard consumer0.pop()

  var producer1 = queue.getProducer(1)
  discard producer1.push(@[9, 10, 11, 12])

  var items = newSeq[int]()
  for i in 1..8:
    let res = consumer0.pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(
    head = 12,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 1,
    producerTails = (@[8, 12, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[12, 0, 0, 0]),
  )


template testMucPopCountOne*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  check(producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  var consumer0 = queue.getConsumer(0)
  for i in 1..8:
    let popped = consumer0.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 0,
    producerTails = (@[8, 0, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testMucPopCountAll*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  discard producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var consumer0 = queue.getConsumer(0)
  let popped = consumer0.pop(8)

  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 0,
    producerTails = (@[8, 0, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testMucPopCountEmpty*(queue: untyped) =
  var consumer0 = queue.getConsumer(0)
  let popped = consumer0.pop(1)
  check(popped.isNone)
  queue.checkState(
    head = 0,
    tail = 0,
    storage = repeat(0, 8),
  )
  queue.checkState(
    prevProducerIdx = NoProducerIdx,
    producerTails = repeat(0, 4),
  )
  queue.checkState(
    prevConsumerIdx = NoConsumerIdx,
    consumerHeads = repeat(0, 4),
  )


template testMucPopCountTooMany*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  check(producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  queue.checkState(
    head = 0,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )

  var consumer0 = queue.getConsumer(0)
  let popped = consumer0.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(
    head = 8,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 0,
    producerTails = (@[8, 0, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 0,
    consumerHeads = (@[8, 0, 0, 0]),
  )


template testMucPopCountWrap*(queue: untyped) =
  var producer0 = queue.getProducer(0)
  discard producer0.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var consumer0 = queue.getConsumer(0)
  discard consumer0.pop(4)

  var producer1 = queue.getProducer(1)
  discard producer1.push(@[9, 10, 11, 12])

  var consumer1 = queue.getConsumer(1)
  let popped = consumer1.pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(
    head = 12,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
  queue.checkState(
    prevProducerIdx = 1,
    producerTails = (@[8, 12, 0, 0]),
  )
  queue.checkState(
    prevConsumerIdx = 1,
    consumerHeads = (@[4, 12, 0, 0]),
  )
