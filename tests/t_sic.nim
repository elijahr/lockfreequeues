# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.


template testSicPopOne*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let res = queue.pop()
  check(res.isSome)
  check(res.get == 1)

  queue.checkState(
    head=1,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=0,
      producerTails=(@[8, 0, 0, 0]),
    )


template testSicPopAll*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var items = newSeq[int]()
  for i in 1..8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(
    head=8,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=0,
      producerTails=(@[8, 0, 0, 0]),
    )

template testSicPopEmpty*(queue: untyped) =
  check(queue.pop().isNone)

  queue.checkState(
    head=0,
    tail=0,
    storage=repeat(0, 8),
  )

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=NoProducerIdx,
      producerTails=repeat(0, 4),
    )


template testSicPopTooMany*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1..8:
    discard queue.pop()

  check(queue.pop().isNone)

  queue.checkState(
    head=8,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=0,
      producerTails=(@[8, 0, 0, 0]),
    )


template testSicPopWrap*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1..4:
    discard queue.pop()

  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(1).push(@[9, 10, 11, 12])
  else:
    discard queue.push(@[9, 10, 11, 12])

  var items = newSeq[int]()
  for i in 1..8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(
    head=12,
    tail=12,
    storage=(@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=1,
      producerTails=(@[8, 12, 0, 0]),
    )


template testSicPopCountOne*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1..8:
    let popped = queue.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])

  queue.checkState(
    head=8,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=0,
      producerTails=(@[8, 0, 0, 0]),
    )


template testSicPopCountAll*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(
    head=8,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=0,
      producerTails=(@[8, 0, 0, 0]),
    )


template testSicPopCountEmpty*(queue: untyped) =
  let popped = queue.pop(1)
  check(popped.isNone)
  queue.checkState(
    head=0,
    tail=0,
    storage=repeat(0, 8),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=NoProducerIdx,
      producerTails=repeat(0, 4),
    )


template testSicPopCountTooMany*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let popped = queue.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(
    head=8,
    tail=8,
    storage=(@[1, 2, 3, 4, 5, 6, 7, 8]),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=0,
      producerTails=(@[8, 0, 0, 0]),
    )


template testSicPopCountWrap*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  discard queue.pop(4)

  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(1).push(@[9, 10, 11, 12])
  else:
    discard queue.push(@[9, 10, 11, 12])

  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(
    head=12,
    tail=12,
    storage=(@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(
      prevProducerIdx=1,
      producerTails=(@[8, 12, 0, 0]),
    )
