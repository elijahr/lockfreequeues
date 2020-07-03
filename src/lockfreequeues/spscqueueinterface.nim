# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Single-producer, single-consumer, lock-free queue implementations for Nim.
##
## Based on the algorithm outlined by Juho Snellman at
## https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/

import atomics
import bitops
import options


# Size of cache line, used to prevent cache thrashing,
# since reads/writes to each will be on different threads.
const CACHELINE_BYTES = when defined(powerpc):
  128
else:
  64


type
  SPSCQueueInterface* = object
    head*: Atomic[uint]
    # padding forces head and tail to different cache lines
    padding: array[CACHELINE_BYTES, char]
    tail*: Atomic[uint]


proc index*(
  value: uint,
  capacity: uint
): uint
  {.inline.} =
  ## Convert a head or tail value to its index in storage.
  return bitand(value, capacity - 1u)


proc size*(
  head: uint,
  tail: uint,
): uint
  {.inline.} =
  return tail - head


proc size*(
  self: var SPSCQueueInterface,
): uint
  {.inline.} =
  let tail = self.tail.load(moRelaxed)
  let head = self.head.load(moRelaxed)
  return tail - head


proc available*(
  head: uint,
  tail: uint,
  capacity: uint,
): uint
  {.inline.} =
  ## Determine how many slots are available given `head`, `tail`, and `capacity`
  ## values.
  return capacity - (tail - head)


proc available*(
  self: var SPSCQueueInterface,
  capacity: uint,
): uint
  {.inline.} =
  ## Determine how many slots are available in the given `SPSCQueueInterface`
  ## for max `capacity` items.
  return capacity - self.size


proc full*(
  head: uint,
  tail: uint,
  capacity: uint,
): bool
  {.inline.} =
  ## Determine if storage is full given `head`, `tail`, and `capacity` values.
  return (tail - head) == capacity


proc empty*(
  head: uint,
  tail: uint,
): bool
  {.inline.} =
  ## Determine if storage is empty given `head` and `tail` values.
  return head == tail


template doPush(
  self: var SPSCQueueInterface,
  storage: untyped,
  capacity: int,
  item: untyped,
) =
  ## Append a single item to the tail of the queue.
  ## If the item was appended, `true` is returned.
  ## If the queue is full, `false` is returned.

  let tail = self.tail.load(moRelaxed)
  let head = self.head.load(moAcquire)
  let cap = cast[uint](capacity)

  if unlikely(full(head, tail, cap)):
    # queue is full, return false
    return false

  let writeIndex = index(tail, cap)

  storage[writeIndex] = item

  result = true

  # Values above high(uint) will overflow and reset from zero.
  # This allows for an ever-increasing tail and removes the need for storing an
  # additional "empty" or "full" state.
  self.tail.store(tail + 1, moRelease)


proc push*[T](
  self: var SPSCQueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
  item: T,
):
  bool =
  ## Append a single item to the tail of the queue.
  ## If the item was appended, `true` is returned.
  ## If the queue is full, `false` is returned.
  self.doPush(storage, capacity, item)


proc push*[N: static int, T](
  self: var SPSCQueueInterface,
  storage: var array[N, T],
  item: T,
):
  bool =
  ## Append a single item to the tail of the queue.
  ## If the item was appended, `true` is returned.
  ## If the queue is full, `false` is returned.
  self.doPush(storage, N, item)


template push(
  self: var SPSCQueueInterface,
  storage: untyped,
  capacity: int,
  items: untyped,
  rettype: typedesc,
) =
  ## Append items to the tail of the queue.
  ## If > 1 items could not be appended, `some(unpushed)` will be returned.
  ## Otherwise, `none(seq[T])` will be returned.

  let tail = self.tail.load(moRelaxed)
  let head = self.head.load(moAcquire)
  let cap = cast[uint](capacity)
  let itemCount = cast[uint](items.len)

  if unlikely(itemCount == 0u):
    # items is empty, return nothing
    return none(rettype)

  if unlikely(full(head, tail, cap)):
    # queue is full, return everything
    return some(items[0..^1])

  let avail = available(head, tail, cap)
  var newTail: uint

  if likely(avail >= itemCount):
    # enough room to push all items, return nothing
    result = none(rettype)
    newTail = tail + itemCount
  else:
    # not enough room to push all items, return remainder
    result = some(items[avail..^1])
    newTail = tail + avail

  let writeStartIndex = index(tail, cap)
  var writeEndIndex = index(newTail-1, cap)

  if writeStartIndex > writeEndIndex:
    # data may wrap
    let itemsPivotIndex = (cap-1u) - writeStartIndex
    for i in 0..itemsPivotIndex:
      storage[writeStartIndex+i] = items[i]
    if writeEndIndex > 0:
      # data wraps
      for i in 0..writeEndIndex:
        storage[i] = items[itemsPivotIndex+1+i]
  else:
    # data does not wrap
    for i in 0..writeEndIndex-writeStartIndex:
      storage[writeStartIndex+i] = items[i]

  # Values above high(uint) will overflow and reset from zero.
  # This allows for an ever-increasing tail and removes the need for storing an
  # additional "empty" or "full" state.
  self.tail.store(newTail, moRelease)


proc push*[T](
  self: var SPSCQueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
  items: openArray[T],
):
  Option[seq[T]] =
  ## Append items to the tail of the queue.
  ## If > 1 items could not be appended, `some(unpushed)` will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  self.push(storage, capacity, items, seq[T])


proc push*[N: static int, T](
  self: var SPSCQueueInterface,
  storage: var array[N, T],
  items: openArray[T],
):
  Option[seq[T]] =
  ## Append items to the tail of the queue.
  ## If > 1 items could not be appended, `some(unpushed)` will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  self.push(storage, N, items, seq[T])


template popOne(
  self: var SPSCQueueInterface,
  storage: untyped,
  capacity: int,
  rettype: typedesc,
) =
  ## Pop a single item from the head of the queue.
  ## If an item could be popped, some(T) will be returned.
  ## Otherwise, `none(T)` will be returned.
  let tail = self.tail.load(moAcquire)
  let head = self.head.load(moRelaxed)
  let size = size(head, tail)

  if unlikely(size == 0u or empty(head, tail)):
    return none(T)

  let headIndex = index(head, cast[uint](capacity))

  result = some(storage[headIndex])

  # Values above high(uint) will overflow and reset from zero.
  # This allows for an ever-increasing head and removes the need for storing an
  # additional "empty" or "full" state.
  self.head.store(head + 1, moRelease)


proc pop*[T](
  self: var SPSCQueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
):
  Option[T] =
  ## Pop a single item from the head of the queue.
  ## If an item could be popped, some(T) will be returned.
  ## Otherwise, `none(T)` will be returned.
  self.popOne(storage, capacity, T)


proc pop*[N: static int, T](
  self: var SPSCQueueInterface,
  storage: var array[N, T],
):
  Option[T] =
  ## Pop a single item from the head of the queue.
  ## If an item could be popped, some(T) will be returned.
  ## Otherwise, `none(T)` will be returned.
  self.popOne(storage, N, T)


template popMany(
  self: var SPSCQueueInterface,
  storage: untyped,
  capacity: int,
  count: int,
  rettype: typedesc,
) =
  ## Pop `count` items from the head of the queue.
  ## If > 1 items could be popped, some(seq[T]) will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  let tail = self.tail.load(moAcquire)
  let head = self.head.load(moRelaxed)
  let size = size(head, tail)

  if unlikely(size == 0u or empty(head, tail)):
    return none(seq[T])

  let itemCount =
    if likely(size >= cast[uint](count)):
      # enough data to pop count
      cast[uint](count)
    else:
      # not enough data to pop count
      size

  var res = newSeq[T](itemCount)
  let newHead = head + itemCount
  let cap = cast[uint](capacity)
  let headIndex = index(head, cap)
  let newHeadIndex = index(newHead, cap)

  if headIndex < newHeadIndex:
    # request does not wrap
    for i in 0..itemCount-1:
      res[i] = storage[headIndex+i]
  else:
    # request may wrap
    var i = 0
    for j in headIndex..cap-1:
      res[i] = storage[j]
      inc i
    if newHeadIndex > 0:
      # request wraps
      for j in 0..newHeadIndex-1:
        res[i] = storage[j]
        inc i

  result = some(res)

  # Values above high(uint) will overflow and reset from zero.
  # This allows for an ever-increasing head and removes the need for storing an
  # additional "empty" or "full" state.
  self.head.store(newHead, moRelease)


proc pop*[T](
  self: var SPSCQueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
  count: int,
):
  Option[seq[T]] =
  ## Pop `count` items from the head of the queue.
  ## If > 1 items could be popped, some(seq[T]) will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  self.popMany(storage, capacity, count, seq[T])


proc pop*[N: static int, T](
  self: var SPSCQueueInterface,
  storage: var array[N, T],
  count: int,
):
  Option[seq[T]] =
  ## Pop `count` items from the head of the queue.
  ## If > 1 items could be popped, some(seq[T]) will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  self.popMany(storage, N, count, seq[T])


proc state*(
  self: var SPSCQueueInterface,
): tuple[
    head: uint,
    tail: uint,
  ] =
  ## Retrieve current state of the queue.
  ## Probably only useful for unit tests.
  return (
    head: self.head.load(moRelaxed),
    tail: self.tail.load(moRelaxed),
  )


proc move*(
  self: var SPSCQueueInterface,
  head: uint,
  tail: uint
) =
  ## Move head and tail.
  ## Probably only useful for unit tests.
  self.head.store(head, moRelease)
  self.tail.store(tail, moRelease)