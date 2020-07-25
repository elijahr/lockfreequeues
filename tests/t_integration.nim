

template testCapacity*(queue: untyped) =
  check(queue.capacity == 8)


template testHeadAndTailReset*(queue: untyped) =
  queue.head.release(15)
  queue.tail.release(15)
  when queue is MupStaticQueue:
    queue.producers[0].release(Producer(
      tail: 15,
      state: Synchronized,
      prevPid: 0,
    ))
    check(queue.state == (
      head: 15,
      tail: 15,
      prevPid: 0,
      storage: repeat(0, 8),
      producers: @[
        Producer(tail: 15, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
    check(queue.push(0, @[1]).isNone)
    check(queue.state == (
      head: 15,
      tail: 0,
      prevPid: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1],
      producers: @[
        Producer(tail: 0, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
  else:
    check(queue.state == (
      head: 15,
      tail: 15,
      storage: repeat(0, 8)
    ))
    check(queue.push(@[1]).isNone)
    check(queue.state == (
      head: 15,
      tail: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1],
    ))
  let res = queue.pop(1)
  check(res.isSome)
  check(res.get == @[1])
  when queue is MupStaticQueue:
    check(queue.state == (
      head: 0,
      tail: 0,
      prevPid: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1],
      producers: @[
        Producer(tail: 0, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
  else:
    check(queue.state == (
      head: 0,
      tail: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1]
    ))


template testWraps*(queue: untyped) =
  when queue is MupStaticQueue:
    check(queue.push(0, @[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  else:
    check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  var  res = queue.pop(4)
  check(res.isSome)
  check(res.get() == @[1, 2, 3, 4])
  when queue is MupStaticQueue:
   res = queue.push(0, @[9, 10, 11, 12])
  else:
   res = queue.push(@[9, 10, 11, 12])
  check(res.isNone)
  when queue is MupStaticQueue:
    check(queue.state == (
      head: 4,
      tail: 12,
      prevPid: 0,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 12, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
  else:
    check(queue.state == (
      head: 4,
      tail: 12,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8]
    ))
  res = queue.pop(4)
  check(res.isSome)
  check(res.get() == @[5, 6, 7, 8])
  when queue is MupStaticQueue:
    check(queue.state == (
      head: 8,
      tail: 12,
      prevPid: 0,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 12, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
  else:
    check(queue.state == (
      head: 8,
      tail: 12,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8]
    ))
  res = queue.pop(4)
  check(res.isSome)
  check(res.get() == @[9, 10, 11, 12])
  when queue is MupStaticQueue:
    check(queue.state == (
      head: 12,
      tail: 12,
      prevPid: 0,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8],
      producers: @[
        Producer(tail: 12, state: Synchronized, prevPid: 0),
        initialProducer,
        initialProducer,
        initialProducer,
      ],
    ))
  else:
    check(queue.state == (
      head: 12,
      tail: 12,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8]
    ))
