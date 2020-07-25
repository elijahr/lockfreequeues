# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, single-consumer queue, implemented as a ring buffer,
## suitable for when the capacity is only known at run-time or when the queue
## should reside in shared memory.

import atomics
import options
import strformat

import ./constants
import ./sic_ops
import ./sip_ops


type
  SipsicSharedQueue*[T] = object
    ## A single-producer, single-consumer queue, implemented as a ring buffer,
    ## suitable for when the capacity is only known at run-time or when the
    ## queue should reside in shared memory.
    ##
    ## A `SipsicSharedQueue` is aligned along a cache line, since arrays of queues
    ## are a common use-case.
    capacity* {.align: CacheLineBytes.}: int ## The queue's capacity.
    storage*: ptr UncheckedArray[T] ## The queue's underlying storage.

    # Align head/tail on different cache lines to prevent thrashing,
    # since reads/writes to each will be on different threads.
    head* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]


template itemType*(Q: typedesc[SipsicSharedQueue]): typedesc = Q.T


proc newSipsicQueue*[T](capacity: int):
  ref SipsicSharedQueue[T] =
  ## Initialize a new `SipsicSharedQueue` and validate its capacity.
  if capacity == 0:
    raise newException(ValueError, fmt"capacity ({capacity}) must be > 0")
  new(result)
  result[].capacity = capacity.int
  result[].head.release(0)
  result[].tail.release(0)
  result[].storage = cast[ptr UncheckedArray[T]](
    alloc0(sizeof(T) * capacity.int)
  )


template itemType*(Q: typedesc[SipsicSharedQueue]): typedesc = Q.T


proc `=deepCopy`*[T](x: ref SipsicSharedQueue[T]): ref SipsicSharedQueue[T] =
  ## Prevent deep copy to ensure the queue is shared between threads
  result = x


proc `=destroy`*[T](self: var SipsicSharedQueue[T]) =
  if self.storage != nil:
    dealloc(self.storage)
    self.storage = nil


proc push*[T](
  self: ref SipsicSharedQueue[T],
  item: T,
):
  bool
  {.inline.} =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  result = sipSharedPushOne(self, item)


proc push*[T](
  self: ref SipsicSharedQueue[T],
  items: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  result = sipSharedPushMany(self, items)


proc pop*[T](
  self: ref SipsicSharedQueue[T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  result = sicSharedPopOne(self)


proc pop*[T](
  self: ref SipsicSharedQueue[T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  result = sicSharedPopMany(self, count)

