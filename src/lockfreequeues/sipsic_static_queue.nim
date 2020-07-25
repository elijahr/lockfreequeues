# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer queue, implemented as a ring buffer,
## suitable for when the capacity is known at compile-time.

import atomics
import options
import strformat

import ./constants
import ./sic_ops
import ./sip_ops


type
  SipsicStaticQueue*[N: static int, T] = object
    ## A single-producer, single-consumer queue, implemented as a ring buffer,
    ## suitable for when the capacity is known at compile-time.
    ##
    ## A `SipsicStaticQueue` is aligned along a cache line, since arrays of queues
    ## are a common use-case.
    # Align head/tail on different cache lines to prevent thrashing,
    # since reads/writes to each will be on different threads.
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]

    storage*: array[N, T] ## The queue's underlying storage.


template itemType*(Q: typedesc[SipsicStaticQueue]): typedesc = Q.T


proc initSipsicQueue*[N: static int, T](): SipsicStaticQueue[N, T] =
  ## Initialize a new `SipsicStaticQueue` and validate its capacity.
  if N == 0:
    raise newException(ValueError, fmt"N ({N}) must be > 0")


proc push*[N: static int, T](
  self: var SipsicStaticQueue[N, T],
  item: T,
):
  bool
  {.inline.} =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  result = sipStaticPushOne(self, item)


proc push*[N: static int, T](
  self: var SipsicStaticQueue[N, T],
  items: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  result = sipStaticPushMany(self, items)


proc pop*[N: static int, T](
  self: var SipsicStaticQueue[N, T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  result = sicStaticPopOne(self)


proc pop*[N: static int, T](
  self: var SipsicStaticQueue[N, T],
  count: SomeInteger,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  result = sicStaticPopMany(self, count)


