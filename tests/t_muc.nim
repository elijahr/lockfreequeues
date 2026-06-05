## Shared test templates for multi-consumer queues (Mpmc).

template testMucPopOne*(queue: untyped) =
  discard (
    block:
      var lfqT = queue.getProducerHere(0)
      lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  )

  var res = (
    block:
      var lfqT = queue.getConsumerHere(0)
      lfqT.pop()
  )
  check(res.isSome)
  check(res.get == 1)

  queue.checkState(head = 1'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopAll*(queue: untyped) =
  discard (
    block:
      var lfqT = queue.getProducerHere(0)
      lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  )

  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop()
    )
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopEmpty*(queue: untyped) =
  check(
    (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop()
    ).isNone
  )

  # Cell payload data is undefined where seq does not mark it published
  # (Vyukov canonical protocol). After reset, head=tail=0 with no published
  # slots — only check head/tail.
  queue.checkState(head = 0'u64, tail = 0'u64)

template testMucPopTooMany*(queue: untyped) =
  discard (
    block:
      var lfqT = queue.getProducerHere(0)
      lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  )

  for i in 1 .. 8:
    discard (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop()
    )

  check(
    (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop()
    ).isNone
  )

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopWrap*(queue: untyped) =
  discard (
    block:
      var lfqT = queue.getProducerHere(0)
      lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  )

  for i in 1 .. 4:
    discard (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop()
    )

  discard (
    block:
      var lfqT = queue.getProducerHere(1)
      lfqT.push(@[9, 10, 11, 12])
  )

  var items = newSeq[int]()
  for i in 1 .. 8:
    var res = (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop()
    )
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

template testMucPopCountOne*(queue: untyped) =
  check(
    (
      block:
        var lfqT = queue.getProducerHere(0)
        lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    ).isNone
  )
  for i in 1 .. 8:
    var popped = (
      block:
        var lfqT = queue.getConsumerHere(0)
        lfqT.pop(1)
    )
    check(popped.isSome)
    check(popped.get() == @[i])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountAll*(queue: untyped) =
  discard (
    block:
      var lfqT = queue.getProducerHere(0)
      lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  )
  var popped = (
    block:
      var lfqT = queue.getConsumerHere(0)
      lfqT.pop(8)
  )
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountEmpty*(queue: untyped) =
  var popped = (
    block:
      var lfqT = queue.getConsumerHere(0)
      lfqT.pop(1)
  )
  check(popped.isNone)
  # Cell payload data is undefined where seq does not mark it published
  # (Vyukov canonical protocol). After reset, head=tail=0 with no published
  # slots — only check head/tail.
  queue.checkState(head = 0'u64, tail = 0'u64)

template testMucPopCountTooMany*(queue: untyped) =
  check(
    (
      block:
        var lfqT = queue.getProducerHere(0)
        lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    ).isNone
  )

  queue.checkState(head = 0'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

  var popped = (
    block:
      var lfqT = queue.getConsumerHere(0)
      lfqT.pop(10)
  )
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  queue.checkState(head = 8'u64, tail = 8'u64, data = (@[1, 2, 3, 4, 5, 6, 7, 8]))

template testMucPopCountWrap*(queue: untyped) =
  discard (
    block:
      var lfqT = queue.getProducerHere(0)
      lfqT.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  )

  discard (
    block:
      var lfqT = queue.getConsumerHere(0)
      lfqT.pop(4)
  )

  discard (
    block:
      var lfqT = queue.getProducerHere(1)
      lfqT.push(@[9, 10, 11, 12])
  )

  var popped = (
    block:
      var lfqT = queue.getConsumerHere(1)
      lfqT.pop(8)
  )
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  queue.checkState(head = 12'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))
