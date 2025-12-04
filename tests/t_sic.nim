# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Shared test templates for single-consumer queues (Sipsic, Mupsic).


template testSicPopOne*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let res = queue.pop()
  check(res.isSome)
  check(res.get == 1)

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 1, reservedTail = 8)
  else:
    queue.checkState(head = 1, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8]))


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

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 8, reservedTail = 8)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8]))


template testSicPopEmpty*(queue: untyped) =
  check(queue.pop().isNone)

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 0, reservedTail = 0)
  else:
    queue.checkState(head = 0, tail = 0, storage = repeat(0, 8))


template testSicPopTooMany*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1..8:
    discard queue.pop()

  check(queue.pop().isNone)

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 8, reservedTail = 8)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8]))


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

  # MPSC: N-slot design wraps at 2*N (virtual slot 12 wraps to 12-16=-4+16=12)
  # SPSC: N+1-slot design, items 9→slot 8, 10→slot 0, 11→slot 1, 12→slot 2
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 12, reservedTail = 12)
  else:
    queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8]))


template testSicPopCountOne*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1..8:
    let popped = queue.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 8, reservedTail = 8)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8]))


template testSicPopCountAll*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 8, reservedTail = 8)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8]))


template testSicPopCountEmpty*(queue: untyped) =
  let popped = queue.pop(1)
  check(popped.isNone)
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 0, reservedTail = 0)
  else:
    queue.checkState(head = 0, tail = 0, storage = repeat(0, 8))


template testSicPopCountTooMany*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let popped = queue.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 8, reservedTail = 8)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8]))


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

  # MPSC: N-slot design wraps at 2*N
  # SPSC: N+1-slot design, items 9→slot 8, 10→slot 0, 11→slot 1, 12→slot 2
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.checkState(head = 12, reservedTail = 12)
  else:
    queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8]))
