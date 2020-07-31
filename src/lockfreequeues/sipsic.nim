# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer queue, implemented as a ring buffer,
## suitable for when the capacity is known at compile-time.

import atomics
import options

import ./constants
import ./ops


type
  Sipsic*[N: static int, T] = object of RootObj
    ## A single-producer, single-consumer queue, implemented as a ring buffer,
    ## suitable for when the capacity is known at compile-time.

    # Align head/tail on different cache lines to prevent thrashing,
    # since reads/writes to each will be on different threads.
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]

    storage*: array[N, T] ## The underlying storage.


proc push*[N: static int, T](
  self: var Sipsic[N, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  let tail = self.tail.relaxed
  let head = self.head.acquire

  if unlikely(full(head, tail, N)):
    # queue is full, return false
    return false

  let writeIndex = index(tail, N)

  self.storage[writeIndex] = item

  result = true

  self.tail.release(incOrReset(tail, 1, N))


proc push*[N: static int, T](
  self: var Sipsic[N, T],
  items: openArray[T],
): Option[seq[T]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  if unlikely(items.len == 0):
    # items is empty, return nothing
    return none(seq[T])

  let tail = self.tail.relaxed
  let head = self.head.acquire

  if unlikely(full(head, tail, N)):
    # queue is full, return everything
    return some(items[0..^1])

  let avail = available(head, tail, N)
  var count: int

  if likely(avail >= items.len):
    # enough room to push all items, return nothing
    count = items.len
  else:
    # not enough room to push all items, return remainder
    result = some(items[avail..^1])
    count = avail

  let writeStartIndex = index(tail, N)
  var writeEndIndex = index((tail + count) - 1, N)

  if writeStartIndex > writeEndIndex:
    # data may wrap
    let itemsPivotIndex = (N-1) - writeStartIndex
    for i in 0..itemsPivotIndex:
      self.storage[writeStartIndex+i] = items[i]
    if writeEndIndex > 0:
      # data wraps
      for i in 0..writeEndIndex:
        self.storage[i] = items[itemsPivotIndex+1+i]
  else:
    # data does not wrap
    for i in 0..writeEndIndex-writeStartIndex:
      self.storage[writeStartIndex+i] = items[i]

  self.tail.release(incOrReset(tail, count, N))


proc pop*[N: static int, T](
  self: var Sipsic[N, T],
): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  let tail = self.tail.acquire
  let head = self.head.relaxed

  if unlikely(empty(head, tail)):
    return

  let headIndex = index(head, N)

  result = some(self.storage[headIndex])

  let newHead = incOrReset(head, 1, N)

  self.head.release(newHead)


proc pop*[N: static int, T](
  self: var Sipsic[N, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  let tail = self.tail.acquire
  let head = self.head.relaxed

  if unlikely(empty(head, tail)):
    return none(seq[T])

  let size = used(head, tail, N)

  let itemCount =
    if likely(size >= count):
      # enough data to pop count
      count
    else:
      # not enough data to pop count
      size

  var res = newSeq[T](itemCount)
  let headIndex = index(head, N)
  let newHead = incOrReset(head, itemCount, N)
  let newHeadIndex = index(newHead, N)

  if headIndex < newHeadIndex:
    # request does not wrap
    for i in 0..<itemCount:
      res[i] = self.storage[headIndex+i]
  else:
    # request may wrap
    var i = 0
    for j in headIndex..<N:
      res[i] = self.storage[j]
      inc i
    if newHeadIndex > 0:
      # request wraps
      for j in 0..<newHeadIndex:
        res[i] = self.storage[j]
        inc i

  result = some(res)

  self.head.release(newHead)


proc capacity*[N: static int, T](
  self: var Sipsic[N, T],
): int
  {.inline.} =
  result = N
