import unittest2


template testSipPush*(queue: untyped) =
  for i in 1..8:
    check(queue.push(i) == true)
  queue.checkState(
    head = 0,
    tail = 8,
    # N+1=9 slots. Items 1-8 at slots 0-7, slot 8 unused.
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]),
  )


template testSipPushOverflow*(queue: untyped) =
  for i in 1..8:
    discard queue.push(i)
  check(queue.push(9) == false)
  queue.checkState(
    head = 0,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]),
  )


template testSipPushWrap*(queue: untyped) =
  for i in 1..4:
    discard queue.push(i)
  for i in 1..2:
    discard queue.pop()
  for i in 5..10:
    check(queue.push(i) == true)
  queue.checkState(
    head = 2,
    tail = 10,
    # With mod 9: tail 4-9 -> slots 4-8, tail 9 -> slot 0
    # slot 0: item 10 (pushed at tail=9, 9 mod 9 = 0)
    # slots 1-3: old values 2,3,4 (slots 1,2 are behind head)
    # slots 4-7: items 5,6,7,8
    # slot 8: item 9 (pushed at tail=8, 8 mod 9 = 8)
    storage = (@[10, 2, 3, 4, 5, 6, 7, 8, 9]),
  )


template testSipPushSeq*(queue: untyped) =
  check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  queue.checkState(
    head = 0,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]),
  )


template testSipPushSeqOverflow*(queue: untyped) =
  let res = queue.push(
    @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  )
  check(res.isSome)
  check(res.get == 8..15)
  queue.checkState(
    head = 0,
    tail = 8,
    storage = (@[1, 2, 3, 4, 5, 6, 7, 8, 0]),
  )


template testSipPushSeqWrap*(queue: untyped) =
  discard queue.push(@[1, 2, 3, 4])
  for i in 1..2:
    discard queue.pop()
  var res = queue.push(@[5, 6, 7, 8, 9, 10])
  check(res.isNone)
  queue.checkState(
    head = 2,
    tail = 10,
    storage = (@[10, 2, 3, 4, 5, 6, 7, 8, 9]),
  )
