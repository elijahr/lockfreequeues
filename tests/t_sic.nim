## Shared test templates for single-consumer queues (Sipsic, Mupsic).

template testSicPopOne*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let res = queue.pop()
  check(res.isSome)
  check(res.get == 1)

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 1'u64, tail = 8'u64)
  else:
    # N+1=9 slots
    queue.checkState(head = 1, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopAll*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[1, 2, 3, 4, 5, 6, 7, 8])

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 8'u64, tail = 8'u64)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopEmpty*(queue: untyped) =
  check(queue.pop().isNone)

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 0'u64, tail = 0'u64)
  else:
    queue.checkState(head = 0, tail = 0, storage = repeat(0, 9))

template testSicPopTooMany*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1 .. 8:
    discard queue.pop()

  check(queue.pop().isNone)

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 8'u64, tail = 8'u64)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopWrap*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  for i in 1 .. 4:
    discard queue.pop()

  when compiles(queue.getProducer(0)):
    discard queue.getProducer(1).push(@[9, 10, 11, 12])
  else:
    discard queue.push(@[9, 10, 11, 12])

  var items = newSeq[int]()
  for i in 1 .. 8:
    let res = queue.pop()
    check(res.isSome)
    items.add(res.get)

  check(items == @[5, 6, 7, 8, 9, 10, 11, 12])

  # MPSC: N-slot design wraps at 2*N (virtual slot 12 wraps to 12-16=-4+16=12)
  # SPSC: N+1-slot design with mod 9:
  #   items 9→slot 8 (8 mod 9), 10→slot 0 (9 mod 9), 11→slot 1 (10 mod 9), 12→slot 2 (11 mod 9)
  when compiles(queue.getProducer(0)):
    queue.checkState(head = 12'u64, tail = 12'u64)
  else:
    queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))

template testSicPopCountOne*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  for i in 1 .. 8:
    let popped = queue.pop(1)
    check(popped.isSome)
    check(popped.get() == @[i])

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 8'u64, tail = 8'u64)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopCountAll*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])
  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])
  when compiles(queue.getProducer(0)):
    queue.checkState(head = 8'u64, tail = 8'u64)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopCountEmpty*(queue: untyped) =
  let popped = queue.pop(1)
  check(popped.isNone)
  when compiles(queue.getProducer(0)):
    queue.checkState(head = 0'u64, tail = 0'u64)
  else:
    queue.checkState(head = 0, tail = 0, storage = repeat(0, 9))

template testSicPopCountTooMany*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  let popped = queue.pop(10)
  check(popped.isSome)
  check(popped.get() == @[1, 2, 3, 4, 5, 6, 7, 8])

  when compiles(queue.getProducer(0)):
    queue.checkState(head = 8'u64, tail = 8'u64)
  else:
    queue.checkState(head = 8, tail = 8, storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]))

template testSicPopCountWrap*(queue: untyped) =
  when compiles(queue.getProducer(0)):
    discard queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8])
  else:
    discard queue.push(@[1, 2, 3, 4, 5, 6, 7, 8])

  discard queue.pop(4)

  when compiles(queue.getProducer(0)):
    discard queue.getProducer(1).push(@[9, 10, 11, 12])
  else:
    discard queue.push(@[9, 10, 11, 12])

  let popped = queue.pop(8)
  check(popped.isSome)
  check(popped.get() == @[5, 6, 7, 8, 9, 10, 11, 12])

  # MPSC: N-slot design wraps at 2*N
  # SPSC: N+1-slot design with mod 9
  when compiles(queue.getProducer(0)):
    queue.checkState(head = 12'u64, tail = 12'u64)
  else:
    queue.checkState(head = 12, tail = 12, storage = (@[10, 11, 12, 4, 5, 6, 7, 8, 9]))
