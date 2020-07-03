# SPSCQueueShared
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer, lock-free, wait-free queue.
##
## Based on the algorithm outlined by Juho Snellman at
## https://www.snellman.net/blog/archive/2016-12-13-ring-queues/

import atomics
import math
import options
import strformat

import ./SPSCQueueInterface

type
  SPSCQueueStatic*[N: static int, T] = object
    ## A single-producer, single-consumer queue, suitable for capacity known at
    ## compile time.
    face: ptr SPSCQueueInterface
    storage: array[N, T]


proc newSPSCQueue*[N: static int, T](): SPSCQueueStatic[N, T] =
  ## Initialize new SPSCQueueStatic and validate capacity.
  if N < 2 or not isPowerOfTwo(N):
    raise newException(ValueError, fmt"{N} is not a power of two")
  result.face = cast[ptr SPSCQueueInterface](
    allocShared0(sizeof(SPSCQueueInterface))
  )
  result.move(0, 0)


proc `=destroy`*[N: static int, T](self: var SPSCQueueStatic[N, T]) =
  if self.face != nil:
    deallocShared(self.face)


proc push*[N: static int, T](
  self: var SPSCQueueStatic[N, T],
  data: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Push items to the SPSCQueueShared.
  ## If > 1 items could not be pushed, some(unpushed) will be returned.
  ## Otherwise, none(seq[T]) will be returned.
  return self.face[].push(self.storage, data)


proc pop*[N: static int, T](
  self: var SPSCQueueStatic[N, T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop items to the SPSCQueueShared.
  ## If > 1 items could be popped, some(seq[T]) will be returned.
  ## Otherwise, none(seq[T]) will be returned.
  return self.face[].pop(self.storage, count)


proc capacity*[N: static int, T](
  self: var SPSCQueueStatic[N, T],
):
  int
  {.inline.} =
  ## Return the SPSCQueueStatic's capacity
  return self.storage.len


proc state*[N: static int, T](
  self: var SPSCQueueStatic[N, T],
): tuple[
    head: uint,
    tail: uint,
    storage: seq[T],
  ] =
  ## Retrieve current state of the SPSCQueueStatic
  let faceState = self.face[].state
  return (
    head: faceState.head,
    tail: faceState.tail,
    storage: self.storage[0..^1],
  )


proc move*[N: static int, T](
  self: var SPSCQueueStatic[N, T],
  head: uint,
  tail: uint,
) {.inline.} =
  ## Move head and tail. Probably only useful for unit tests.
  self.face[].move(head, tail)


proc reset*[N: static int, T](
  self: var SPSCQueueStatic[N, T]
) {.inline.} =
  ## Resets the queue to its default state
  self.move(0'u, 0'u)
  for i in 0..self.capacity-1:
    self.storage[i].reset()
