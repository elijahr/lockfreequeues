# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer queue, implemented as a ring buffer,
## suitable for when the capacity is known at compile-time.

import options

import ./queueinterface

type
  StaticQueue*[N: static int, T] = object
    ## A single-producer, single-consumer queue, implemented as a ring buffer,
    ## suitable for when the capacity is known at compile-time.
    ##
    ## A `StaticQueue` is aligned along a cache line, since arrays of queues are a
    ## common use-case.
    face* {.align: CACHELINE_BYTES.}: QueueInterface ## The queue's \
      ## `QueueInterface <queueinterface.html#QueueInterface>`_.
    storage*: array[N, T] ## The queue's underlying storage.


proc newSPSCQueue*[N: static int, T](): StaticQueue[N, T] =
  ## Initialize a new `StaticQueue` and validate its capacity.
  result.face.move(0, 0, N)


proc push*[N: static int, T](
  self: var StaticQueue[N, T],
  item: T,
):
  bool
  {.inline.} =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  return self.face.push(self.storage, item)


proc push*[N: static int, T](
  self: var StaticQueue[N, T],
  items: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  return self.face.push(self.storage, items)


proc pop*[N: static int, T](
  self: var StaticQueue[N, T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  return self.face.pop(self.storage)


proc pop*[N: static int, T](
  self: var StaticQueue[N, T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  return self.face.pop(self.storage, count)


proc capacity*[N: static int, T](
  self: var StaticQueue[N, T],
):
  int
  {.inline.} =
  ## Return the queue's capacity.
  return N

