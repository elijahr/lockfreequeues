# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

template testCapacity*(queue: untyped) =
  check(queue.capacity == 8)


template testHeadAndTailReset*(queue: untyped) =
  queue.head.release(15)
  queue.tail.release(15)
  when queue is Mupsic:
    queue.prevPid.release(0)
    queue.producers[0].release(15)
    check(queue.state == (
      head: 15,
      tail: 15,
      prevPid: 0,
      storage: repeat(0, 8),
      producers: @[
        15,
        0,
        0,
        0,
      ],
    ))
    check(queue.push(0, @[1]).isNone)
    check(queue.state == (
      head: 15,
      tail: 0,
      prevPid: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1],
      producers: @[
        0,
        0,
        0,
        0,
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
  when queue is Mupsic:
    check(queue.state == (
      head: 0,
      tail: 0,
      prevPid: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1],
      producers: @[
        0,
        0,
        0,
        0,
      ],
    ))
  else:
    check(queue.state == (
      head: 0,
      tail: 0,
      storage: @[0, 0, 0, 0, 0, 0, 0, 1]
    ))


template testWraps*(queue: untyped) =
  when queue is Mupsic:
    check(queue.push(0, @[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  else:
    check(queue.push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  var popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[1, 2, 3, 4])
  var pushRes: Option[HSlice[int, int]]
  when queue is Mupsic:
   pushRes = queue.push(0, @[9, 10, 11, 12])
  else:
   pushRes = queue.push(@[9, 10, 11, 12])
  check(pushRes.isNone)
  when queue is Mupsic:
    check(queue.state == (
      head: 4,
      tail: 12,
      prevPid: 0,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8],
      producers: @[
        12,
        0,
        0,
        0,
      ],
    ))
  else:
    check(queue.state == (
      head: 4,
      tail: 12,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8]
    ))
  popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[5, 6, 7, 8])
  when queue is Mupsic:
    check(queue.state == (
      head: 8,
      tail: 12,
      prevPid: 0,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8],
      producers: @[
        12,
        0,
        0,
        0,
      ],
    ))
  else:
    check(queue.state == (
      head: 8,
      tail: 12,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8]
    ))
  popRes = queue.pop(4)
  check(popRes.isSome)
  check(popRes.get == @[9, 10, 11, 12])
  when queue is Mupsic:
    check(queue.state == (
      head: 12,
      tail: 12,
      prevPid: 0,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8],
      producers: @[
        12,
        0,
        0,
        0,
      ],
    ))
  else:
    check(queue.state == (
      head: 12,
      tail: 12,
      storage: @[9, 10, 11, 12, 5, 6, 7, 8]
    ))
