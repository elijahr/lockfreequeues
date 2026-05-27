## Shared test templates for multi-consumer queues (Mpmc).

template testMucPopOne*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let res = queue.getConsumer(0).pop()
  check(res.isSome)
  check(res.get == 1)

  queue.checkState(head = 1'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopAll*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.getConsumer(0).pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopEmpty*(queue: untyped) =
  check(queue.getConsumer(0).pop().isNone)

  # Cell payload data is undefined where seq does not mark it published
  # (Vyukov canonical protocol). After reset, head=tail=0 with no published
  # slots — only check head/tail.
  queue.checkState(head = 0'u64, tail = 0'u64)

template testMucPopTooMany*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1 .. 8:
    discard queue.getConsumer(0).pop()

  check(queue.getConsumer(0).pop().isNone)

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopWrap*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1 .. 4:
    discard queue.getConsumer(0).pop()

  discard queue.getProducer(1).push(@[9, 10, 11, 12])

  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.getConsumer(0).pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testMucPopCountOne*(queue: untyped) =
  check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  for i in 1 .. 8:
    let popped = queue.getConsumer(0).pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountAll*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.getConsumer(0).pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountEmpty*(queue: untyped) =
  let popped = queue.getConsumer(0).pop(1)
  check(popped.isNone)
  # Cell payload data is undefined where seq does not mark it published
  # (Vyukov canonical protocol). After reset, head=tail=0 with no published
  # slots — only check head/tail.
  queue.checkState(head = 0'u64, tail = 0'u64)

template testMucPopCountTooMany*(queue: untyped) =
  check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  queue.checkState(head = 0'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

  let popped = queue.getConsumer(0).pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountWrap*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])

  discard queue.getConsumer(0).pop(4)

  discard queue.getProducer(1).push(@[9, 10, 11, 12])

  let popped = queue.getConsumer(1).pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))
