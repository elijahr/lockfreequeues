# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import lockfreequeues/sipmuc


template testCapacity*(queue: untyped) =
  check(queue.capacity == 8)


template testHeadAndTailReset*(queue: untyped) =
  queue.head.sequential(15)
  queue.tail.sequential(15)
  when ((queue is Mupsic) or (queue is Mupmuc)):
    queue.reservedTail.sequential(15)
  when ((queue is Mupmuc) or (queue is Sipmuc)):
    queue.reservedHead.sequential(15)
  queue.checkState(
    head = 15,
    tail = 15,
    storage = repeat(0, 8),
  )

  when ((queue is Mupsic) or (queue is Mupmuc)):
    check(queue.getProducer(0).push(@[1]).isNone)
  else:
    check(queue.push(@[1]).isNone)

  queue.checkState(
    head = 15,
    tail = 0,
    storage = (@[0, 0, 0, 0, 0, 0, 0, 1]),
  )

  let res =
    when ((queue is Mupmuc) or (queue is Sipmuc)):
      queue.getConsumer(0).pop(1)
    else:
      queue.pop(1)

  check(res.isSome)
  check(res.get == @[1])
  queue.checkState(
    head = 0,
    tail = 0,
    storage = (@[0, 0, 0, 0, 0, 0, 0, 1]),
  )


template testWraps*(queue: untyped) =
  when ((queue is Mupsic) or (queue is Mupmuc)):
    check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  else:
    check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)

  var popRes =
    when ((queue is Mupmuc) or (queue is Sipmuc)):
      queue.getConsumer(0).pop(4)
    else:
      queue.pop(4)

  check(popRes.isSome)
  check(popRes.get == @[1, 2, 3, 4])

  let pushRes =
    when ((queue is Mupsic) or (queue is Mupmuc)):
       queue.getProducer(0).push(@[9, 10, 11, 12])
     else:
      queue.push(@[9, 10, 11, 12])

  check(pushRes.isNone)

  queue.checkState(
    head = 4,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )

  popRes =
    when ((queue is Mupmuc) or (queue is Sipmuc)):
      queue.getConsumer(0).pop(4)
    else:
      queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[5, 6, 7, 8])

  queue.checkState(
    head = 8,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )

  popRes =
    when ((queue is Mupmuc) or (queue is Sipmuc)):
      queue.getConsumer(1).pop(4)
    else:
      queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[9, 10, 11, 12])

  queue.checkState(
    head = 12,
    tail = 12,
    storage = (@[9, 10, 11, 12, 5, 6, 7, 8]),
  )
