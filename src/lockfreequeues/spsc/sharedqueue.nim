# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer queue, implemented as a ring buffer,
## suitable for when the capacity is only known at run-time or when the queue
## should reside in shared memory.

import options

import ../constants
import ./queueinterface


type
  SharedQueue*[T] = object
    ## A single-producer, single-consumer queue, implemented as a ring buffer,
    ## suitable for when the capacity is only known at run-time or when the
    ## queue should reside in shared memory.
    ##
    ## A `SharedQueue` is aligned along a cache line, since arrays of queues are a
    ## common use-case.
    capacity* {.align: CACHELINE_BYTES.}: int ## The queue's capacity.
    face*: ptr QueueInterface ## The queue's \
      ## `QueueInterface <queueinterface.html#QueueInterface>`_.
    storage*: ptr UncheckedArray[T] ## The queue's underlying storage.


proc newSPSCQueue*[T](capacity: int):
  SharedQueue[T] =
  ## Initialize a new `SharedQueue` and validate its capacity.
  result.capacity = capacity
  result.face = cast[ptr QueueInterface](
    allocShared0(sizeof(QueueInterface))
  )
  result.face[].move(0, 0, capacity)
  result.storage = cast[ptr UncheckedArray[T]](
    allocShared0(sizeof(T) * capacity)
  )


proc `=destroy`*[T](self: var SharedQueue[T]) =
  if self.face != nil:
    deallocShared(self.face)
    self.face = nil
  if self.storage != nil:
    deallocShared(self.storage)
    self.storage = nil


proc push*[T](
  self: var SharedQueue[T],
  item: T,
):
  bool
  {.inline.} =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  return self.face[].push(self.storage, self.capacity, item)


proc push*[T](
  self: var SharedQueue[T],
  items: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  return self.face[].push(self.storage, self.capacity, items)


proc pop*[T](
  self: var SharedQueue[T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  return self.face[].pop(self.storage, self.capacity)


proc pop*[T](
  self: var SharedQueue[T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  return self.face[].pop(self.storage, self.capacity, count)

