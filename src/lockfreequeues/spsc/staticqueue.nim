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
import math
import options
import strformat

import ./queueinterface

type
  StaticQueue*[N: static int, T] = object
    ## A single-producer, single-consumer queue, suitable for when the max
    ## is capacity known at compile time.
    face: SPSCQueueInterface
    storage: array[N, T]


proc newSPSCQueue*[N: static int, T](): StaticQueue[N, T] =
  ## Initialize new StaticQueue and validate capacity.
  if N < 2 or not isPowerOfTwo(N):
    raise newException(ValueError, fmt"{N} is not a power of two")
  result.move(0, 0)


proc push*[N: static int, T](
  self: var StaticQueue[N, T],
  item: T,
):
  bool =
  ## Append a single item to the tail of the queue.
  ## If the item was appended, `true` is returned.
  ## If the queue is full, `false` is returned.
  self.face.push(self.storage, item)


proc push*[N: static int, T](
  self: var StaticQueue[N, T],
  items: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append items to the tail of the queue.
  ## If > 1 items could not be appended, `some(unpushed)` will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  return self.face.push(self.storage, items)


proc pop*[N: static int, T](
  self: var StaticQueue[N, T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the head of the queue.
  ## If an item could be popped, some(T) will be returned.
  ## Otherwise, `none(T)` will be returned.
  return self.face.pop(self.storage)


proc pop*[N: static int, T](
  self: var StaticQueue[N, T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the head of the queue.
  ## If > 1 items could be popped, some(seq[T]) will be returned.
  ## Otherwise, `none(seq[T])` will be returned.
  return self.face.pop(self.storage, count)


proc capacity*[N: static int, T](
  self: var StaticQueue[N, T],
):
  int
  {.inline.} =
  ## Return the queue's capacity
  return self.storage.len


proc state*[N: static int, T](
  self: var StaticQueue[N, T],
): tuple[
    head: uint,
    tail: uint,
    storage: seq[T],
  ] =
  ## Retrieve current state of the queue
  let faceState = self.face.state
  return (
    head: faceState.head,
    tail: faceState.tail,
    storage: self.storage[0..^1],
  )


proc move*[N: static int, T](
  self: var StaticQueue[N, T],
  head: uint,
  tail: uint,
) {.inline.} =
  ## Move head and tail. Probably only useful for unit tests.
  self.face.move(head, tail)


proc reset*[N: static int, T](
  self: var StaticQueue[N, T]
) {.inline.} =
  ## Resets the queue to its default state
  self.move(0'u, 0'u)
  for i in 0..self.capacity-1:
    self.storage[i].reset()
