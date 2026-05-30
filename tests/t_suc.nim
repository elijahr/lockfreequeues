## Shared test templates for single-producer, multi-consumer queues (Spmc).

import sequtils

template testSucPopOne*(queue: untyped) =
  ## Test popping one item via Consumer.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var res = queue.getConsumerHere(0).pop()
  check(res.isSome)
  check(res.get == 1)

  queue.checkState(head = 1'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopAll*(queue: untyped) =
  ## Test popping all items via Consumer.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = queue.getConsumerHere(0).pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopEmpty*(queue: untyped) =
  ## Test popping from empty queue.
  check(queue.getConsumerHere(0).pop().isNone)

  # Cell payload data is undefined where seq does not mark it published
  # (Vyukov canonical protocol). After reset, head=tail=0 with no published
  # slots — only check head/tail.
  queue.checkState(head = 0'u64, tail = 0'u64)

template testSucPopTooMany*(queue: untyped) =
  ## Test popping more items than available.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1 .. 8:
    discard queue.getConsumerHere(0).pop()

  check(queue.getConsumerHere(0).pop().isNone)

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopWrap*(queue: untyped) =
  ## Test popping with wraparound.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1 .. 4:
    discard queue.getConsumerHere(0).pop()

  discard queue.push(@[9, 10, 11, 12])

  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = queue.getConsumerHere(0).pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testSucPopCountOne*(queue: untyped) =
  ## Test batch pop of one item at a time.
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  for i in 1 .. 8:
    var popped = queue.getConsumerHere(0).pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopCountAll*(queue: untyped) =
  ## Test batch pop of all items.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  var popped = queue.getConsumerHere(0).pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopCountEmpty*(queue: untyped) =
  ## Test batch pop from empty queue.
  var popped = queue.getConsumerHere(0).pop(1)
  check(popped.isNone)
  # Cell payload data is undefined where seq does not mark it published
  # (Vyukov canonical protocol). After reset, head=tail=0 with no published
  # slots — only check head/tail.
  queue.checkState(head = 0'u64, tail = 0'u64)

template testSucPopCountTooMany*(queue: untyped) =
  ## Test batch pop requesting more than available.
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  queue.checkState(head = 0'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

  var popped = queue.getConsumerHere(0).pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testSucPopCountWrap*(queue: untyped) =
  ## Test batch pop with wraparound.
  discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  discard queue.getConsumerHere(0).pop(4)

  discard queue.push(@[9, 10, 11, 12])

  var popped = queue.getConsumerHere(1).pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testSucGetConsumerAssigns*(queue: untyped) =
  ## Test that getConsumer assigns by thread ID.
  let consumer = queue.getConsumer()
  check(consumer.idx >= 0)
  check(consumer.idx < 4)

template testSucGetConsumerReusesAssigned*(queue: untyped) =
  ## Test that getConsumer reuses previously assigned index.
  let consumer1 = queue.getConsumer()
  let consumer2 = queue.getConsumer()
  check(consumer1.idx == consumer2.idx)

template testSucGetConsumerExplicitIndex*(queue: untyped) =
  ## Test explicit consumer index assignment.
  var consumer = queue.getConsumerHere(2)
  check(consumer.idx == 2)
