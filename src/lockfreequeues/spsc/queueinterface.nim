# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## An interface for managing single-producer, single-consumer queue head/tail
## positions.
##
## Used internally by `SharedQueue <sharedqueue.html#SharedQueue>`_ and
## `StaticQueue <staticqueue.html#StaticQueue>`_.


import atomics
import options
import strformat

import ../constants
import ./ops


type
  QueueInterface* = object
    ## An interface for managing single-producer, single-consumer queue
    ## head/tail positions.

    # Align head/tail on different cache lines to prevent thrashing,
    # since reads/writes to each will be on different threads.
    head* {.align: CACHELINE_BYTES.}: Atomic[int]
    tail* {.align: CACHELINE_BYTES.}: Atomic[int]


template pushOne(
  self: var QueueInterface,
  storage: untyped,
  capacity: int,
  item: untyped,
) =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.

  let tail = self.tail.load(moRelaxed)
  let head = self.head.load(moAcquire)

  if unlikely(full(head, tail, capacity)):
    # queue is full, return false
    return false

  let writeIndex = index(tail, capacity)

  storage[writeIndex] = item

  result = true

  self.tail.store(incOrReset(tail, 1, capacity), moRelease)


proc push*[T](
  self: var QueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
  item: T,
):
  bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  self.pushOne(storage, capacity, item)


proc push*[N: static int, T](
  self: var QueueInterface,
  storage: var array[N, T],
  item: T,
):
  bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  self.pushOne(storage, N, item)


template pushMany(
  self: var QueueInterface,
  storage: untyped,
  capacity: int,
  items: untyped,
  rettype: typedesc,
) =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.

  let tail = self.tail.load(moRelaxed)
  let head = self.head.load(moAcquire)

  if unlikely(items.len == 0):
    # items is empty, return nothing
    return none(rettype)

  if unlikely(full(head, tail, capacity)):
    # queue is full, return everything
    return some(items[0..^1])

  let avail = available(head, tail, capacity)
  var count: int

  if likely(avail >= items.len):
    # enough room to push all items, return nothing
    result = none(rettype)
    count = items.len
  else:
    # not enough room to push all items, return remainder
    result = some(items[avail..^1])
    count = avail

  let writeStartIndex = index(tail, capacity)
  var writeEndIndex = index((tail + count) - 1, capacity)

  if writeStartIndex > writeEndIndex:
    # data may wrap
    let itemsPivotIndex = (capacity-1) - writeStartIndex
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

  self.tail.store(incOrReset(tail, count, capacity), moRelease)


proc push*[T](
  self: var QueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
  items: openArray[T],
):
  Option[seq[T]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  self.pushMany(storage, capacity, items, seq[T])


proc push*[N: static int, T](
  self: var QueueInterface,
  storage: var array[N, T],
  items: openArray[T],
):
  Option[seq[T]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  self.pushMany(storage, N, items, seq[T])


template popOne(
  self: var QueueInterface,
  storage: untyped,
  capacity: int,
  rettype: typedesc,
) =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  let tail = self.tail.load(moAcquire)
  let head = self.head.load(moRelaxed)

  if unlikely(used(head, tail, capacity) == 0):
    return none(T)

  let headIndex = index(head, capacity)

  result = some(storage[headIndex])

  self.head.store(incOrReset(head, 1, capacity), moRelease)


proc pop*[T](
  self: var QueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
):
  Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  self.popOne(storage, capacity, T)


proc pop*[N: static int, T](
  self: var QueueInterface,
  storage: var array[N, T],
):
  Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  self.popOne(storage, N, T)


template popMany(
  self: var QueueInterface,
  storage: untyped,
  capacity: int,
  count: int,
  rettype: typedesc,
) =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  let tail = self.tail.load(moAcquire)
  let head = self.head.load(moRelaxed)

  if unlikely(empty(head, tail)):
    return none(rettype)

  let size = used(head, tail, capacity)

  let itemCount =
    if likely(size >= count):
      # enough data to pop count
      count
    else:
      # not enough data to pop count
      size

  var res = newSeq[T](itemCount)
  let headIndex = index(head, capacity)
  let newHead = incOrReset(head, itemCount, capacity)
  let newHeadIndex = index(newHead, capacity)

  if headIndex < newHeadIndex:
    # request does not wrap
    for i in 0..<itemCount:
      res[i] = storage[headIndex+i]
  else:
    # request may wrap
    var i = 0
    for j in headIndex..<capacity:
      res[i] = storage[j]
      inc i
    if newHeadIndex > 0:
      # request wraps
      for j in 0..<newHeadIndex:
        res[i] = storage[j]
        inc i

  result = some(res)

  self.head.store(newHead, moRelease)


proc pop*[T](
  self: var QueueInterface,
  storage: var ptr UncheckedArray[T],
  capacity: int,
  count: int,
):
  Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  self.popMany(storage, capacity, count, seq[T])


proc pop*[N: static int, T](
  self: var QueueInterface,
  storage: var array[N, T],
  count: int,
):
  Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  self.popMany(storage, N, count, seq[T])


proc move*(
  self: var QueueInterface,
  head: int,
  tail: int,
  capacity: int,
)
  {.raises: [ValueError].} =
  ## Move the queue's head and tail.
  ## Should only be called during queue initialization or in unit tests.
  if capacity < 1:
    raise newException(
      ValueError,
      fmt"capacity ({capacity}) must be > 0"
    )
  if head < 0 or head >= 2 * capacity:
    raise newException(
      ValueError,
      fmt"head ({head}) must be in the range 0..<2*capacity"
    )
  if tail < 0 or tail >= 2 * capacity:
    raise newException(
      ValueError,
      fmt"tail ({tail}) must be in the range 0..<2*capacity"
    )
  self.head.store(head, moRelease)
  self.tail.store(tail, moRelease)
