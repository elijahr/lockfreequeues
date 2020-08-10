# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer bounded queue implemented as a ring
## buffer.

import atomics
import options

import ./constants
import ./ops


const NoSlice* = none(HSlice[int, int])


type
  Sipsic*[N: static int, T] = object of RootObj
    ## A single-producer, single-consumer bounded queue implemented as a ring
    ## buffer. Pushing and popping are both wait-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `T` is the type of data the queue will hold.
    ##
    ## `head` and `tail` are aligned on different cache lines to prevent
    ## thrashing, since reads/writes to each will be on different threads.
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]

    storage*: array[N, T] ## The underlying storage.


proc clear[N: static int, T](
  self: var Sipsic[N, T]
) =
  self.head.relaxed(0)
  self.tail.relaxed(0)
  for n in 0..<N:
    self.storage[n].reset()


proc initSipsic*[N: static int, T](): Sipsic[N, T] =
  ## Initialize a new Sipsic queue.
  result.clear()


proc push*[N: static int, T](
  self: var Sipsic[N, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  let tail = self.tail.relaxed
  let head = self.head.relaxed

  if unlikely(full(head, tail, N)):
    # queue is full, return false
    return false

  let writeIndex = index(tail, N)

  self.storage[writeIndex] = item

  result = true

  let newTail = incOrReset(tail, 1, N)

  self.tail.relaxed(newTail)


proc push*[N: static int, T](
  self: var Sipsic[N, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `NoSlice` is returned.
  if unlikely(items.len == 0):
    # items is empty, return none
    return NoSlice

  let tail = self.tail.relaxed
  let head = self.head.relaxed

  if unlikely(full(head, tail, N)):
    # queue is full, return everything
    return some(0..items.len - 1)

  let avail = available(head, tail, N)
  var count: int

  if likely(avail >= items.len):
    # enough room to push all items, return nothing
    result = NoSlice
    count = items.len
  else:
    # not enough room to push all items, return remainder
    result = some(avail..items.len - 1)
    count = min(avail, N)

  let start = index(tail, N)
  var stop = incOrReset(tail, count - 1, N)
  stop = index(stop, N)

  if start > stop:
    # data may wrap
    let pivot = (N-1) - start
    self.storage[start..start+pivot] = items[0..pivot]
    if stop > 0:
      # data wraps
      self.storage[0..stop] = items[pivot+1..pivot+1+stop]
  else:
    # data does not wrap
    self.storage[start..stop] = items[0..stop-start]

  let newTail = incOrReset(tail, count, N)

  self.tail.relaxed(newTail)


proc pop*[N: static int, T](
  self: var Sipsic[N, T],
): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped, `some(T)` is returned.
  let tail = self.tail.relaxed
  let head = self.head.relaxed

  if unlikely(empty(head, tail, N)):
    return

  let headIndex = index(head, N)

  result = some(self.storage[headIndex])

  let newHead = incOrReset(head, 1, N)

  self.head.relaxed(newHead)


proc pop*[N: static int, T](
  self: var Sipsic[N, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one item.
  let tail = self.tail.relaxed
  let head = self.head.relaxed

  let used = used(head, tail, N)
  var actualCount: int

  if likely(used >= count):
    # Enough items to fulfill request
    actualCount = count
  elif used <= 0:
    # Queue is empty, return nothing
    return none(seq[T])
  else:
    # Not enough items to fulfill request
    actualCount = min(used, N)

  var res = newSeq[T](actualCount)
  let headIndex = index(head, N)
  let newHead = incOrReset(head, actualCount, N)

  let newHeadIndex = index(newHead, N)

  if headIndex < newHeadIndex:
    # request does not wrap
    for i in 0..<actualCount:
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

  self.head.relaxed(newHead)


proc capacity*[N: static int, T](
  self: var Sipsic[N, T],
): int
  {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N


when defined(testing):
  from unittest import check

  proc reset*[N: static int, T](
    self: var Sipsic[N, T]
  ) =
    ## Resets the queue to its default state.
    ## Probably only useful in single-threaded unit tests.
    self.clear()


  proc checkState*[N: static int, T](
    self: var Sipsic[N, T],
    head: int,
    tail: int,
    storage: seq[T],
  ) =
    check(self.head.relaxed == head)
    check(self.tail.relaxed == tail)
    check(self.storage[0..^1] == storage)
