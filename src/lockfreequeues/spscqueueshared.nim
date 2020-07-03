# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer, lock-free, wait-free queue.
##
## Based on the algorithm outlined by Juho Snellman at
## https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/

import atomics
import math
import options
import strformat

import ./spscqueueinterface

type
  SPSCQueueShared*[T] = object
    ## A single-producer, single-consumer queue, suitable for capacity known at
    ## runtime.
    capacity*: int
    face: ptr SPSCQueueInterface
    storage: ptr UncheckedArray[T]


proc newSPSCQueue*[T](capacity: int):
  SPSCQueueShared[T]
  {.raises: [ValueError].} =
  ## Initialize new SPSCQueueShared with the specified capacity.
  if capacity < 2 or not isPowerOfTwo(capacity):
    raise newException(ValueError, fmt"{capacity} is not a power of two")
  result.capacity = capacity
  result.face = cast[ptr SPSCQueueInterface](
    allocShared0(sizeof(SPSCQueueInterface))
  )
  result.storage = cast[ptr UncheckedArray[T]](
    allocShared0(sizeof(T) * capacity)
  )
  result.move(0, 0)


proc `=destroy`*[T](self: var SPSCQueueShared[T]) =
  if self.face != nil:
    deallocShared(self.face)
    self.face = nil
  if self.storage != nil:
    deallocShared(self.storage)
    self.storage = nil


proc push*[T](
  self: var SPSCQueueShared[T],
  item: T,
):
  bool =
  ## Append a single item to the tail of the queue.
  ## If the item was appended, `true` is returned.
  ## If the queue is full, `false` is returned.
  self.face[].push(self.storage, self.capacity, item)


proc push*[T](
  self: var SPSCQueueShared[T],
  items: seq[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append items to the tail of the queue.
  ## If > 1 items could not be appended, `some(unpushed)` will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  return self.face[].push(self.storage, self.capacity, items)


proc push*[N: static int, T](
  self: var SPSCQueueShared[T],
  items: ptr array[N, T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append items to the tail of the queue.
  ## If > 1 items could not be appended, `some(unpushed)` will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  return self.face[].push(self.storage, self.capacity, items)


proc pop*[T](
  self: var SPSCQueueShared[T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the head of the queue.
  ## If an item could be popped, some(T) will be returned.
  ## Otherwise, `none(T)` will be returned.
  return self.face[].pop(self.storage, self.capacity)


proc pop*[T](
  self: var SPSCQueueShared[T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the head of the queue.
  ## If > 1 items could be popped, some(seq[T]) will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  return self.face[].pop(self.storage, self.capacity, count)


proc state*[T](
  self: var SPSCQueueShared[T],
): tuple[
    head: uint,
    tail: uint,
    storage: seq[T],
  ] =
  ## Retrieve current state of the queue
  let faceState = self.face[].state
  var storage = newSeq[T](self.capacity)
  for i in 0..self.capacity-1:
    storage[i] = self.storage[i]
  return (
    head: faceState.head,
    tail: faceState.tail,
    storage: storage,
  )


proc move*[T](
  self: var SPSCQueueShared[T],
  head: uint,
  tail: uint,
) {.inline.} =
  ## Move head and tail. Probably only useful for unit tests.
  self.face[].move(head, tail)


proc reset*[T](
  self: var SPSCQueueShared[T]
) {.inline.} =
  ## Resets the queue to its default state
  self.move(0'u, 0'u)
  for i in 0..self.capacity-1:
    self.storage[i].reset()
