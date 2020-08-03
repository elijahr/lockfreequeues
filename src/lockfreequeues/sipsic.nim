# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A bounded, single-producer, single-consumer queue implemented as a ring
## buffer.

import atomics
import options
import sequtils

import ./constants
import ./ops


type
  Sipsic*[N: static int, T] = object of RootObj
    ## A bounded, single-producer, single-consumer queue implemented as a ring
    ## buffer.
    ##
    ## * `N` is the capacity of the queue.
    ## * `T` is the type of data the queue will hold.
    ##
    ## `head` and `tail` are aligned on different cache lines to prevent
    ## thrashing, since reads/writes to each will be on different threads.
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
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `none(HSlice[int, int])` is returned.
  if unlikely(items.len == 0):
    # items is empty, return none
    return none(HSlice[int, int])

  let tail = self.tail.relaxed
  let head = self.head.acquire

  if unlikely(full(head, tail, N)):
    # queue is full, return everything
    return some(0..items.len - 1)

  let avail = available(head, tail, N)
  var count: int

  if likely(avail >= items.len):
    # enough room to push all items, return nothing
    result = none(HSlice[int, int])
    count = items.len
  else:
    # not enough room to push all items, return remainder
    result = some(avail..items.len - 1)
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
  ## Returns the queue's storage capacity (`N`).
  result = N


proc reset*[N: static int, T](
  self: var Sipsic[N, T]
) {.inline.} =
  ## Resets the queue to its default state.
  ## Proably only useful in single-threaded unit tests.
  doAssert(defined(testing))

  self.head.release(0)
  self.tail.release(0)
  self.storage[0..<N] = repeat(0, N)


proc state*[N: static int, T](
  self: var Sipsic[N, T],
): tuple[
    head: int,
    tail: int,
    storage: seq[T],
  ] =
  ## Retrieve current state of the queue
  ## Proably only useful in single-threaded unit tests,
  ## as data may be torn.
  doAssert(defined(testing))

  return (
    head: self.head.acquire,
    tail: self.tail.acquire,
    storage: self.storage[0..^1],
  )
