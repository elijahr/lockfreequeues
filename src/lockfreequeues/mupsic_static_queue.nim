import atomics
import options
import strformat

import ./atomic_dsl
import ./constants
import ./mup_ops
import ./producer
import ./sic_ops


type
  MupsicStaticQueue*[N, P: static int, T] {.explain.} = object
    head* {.align: CacheLineBytes.}: Atomic[uint32] ## \
      ## The head as seen by both producers and consumers.

    tail*: Atomic[uint32] ## \
      ## The tail as seen by consumers.

    prevPid*: Atomic[uint16] ## \
      ## The ID of the most recent Producer

    storage*: array[N, T] ## The underlying storage

    producers*: array[P, PackedAtomic[Producer, int64]] ## \
      ## Producers packed into int64, for atomic reading/writing


template itemType*(Q: typedesc[MupsicStaticQueue]): typedesc = Q.T


proc initMupsicQueue*[N, P: static int, T](): MupsicStaticQueue[N, P, T] =
  if N.int notin 1..<MaxMupCapacity:
    raise newException(ValueError, fmt"N ({N}) must be in range 1..<{MaxMupCapacity}")
  if P.int notin 1..<MaxProducers:
    raise newException(ValueError, fmt"P ({P}) must be in range 1..<{MaxProducers}")


proc push*[N, P: static int, T](
  self: var MupsicStaticQueue[N, P, T],
  producerId: SomeInteger,
  item: T,
):
  bool
  {.inline.} =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  result = mupStaticPushOne(self, producerId, item)


proc push*[N, P: static int, T](
  self: var MupsicStaticQueue[N, P, T],
  producerId: SomeInteger,
  items: openArray[T],
):
  Option[seq[T]]
  {.inline.} =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  result = mupStaticPushMany(self, producerId, items)


proc pop*[N, P: static int, T](
  self: var MupsicStaticQueue[N, P, T],
):
  Option[T]
  {.inline.} =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  result = sicStaticPopOne(self)


proc pop*[N, P: static int, T](
  self: var MupsicStaticQueue[N, P, T],
  count: int,
):
  Option[seq[T]]
  {.inline.} =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  result = sicStaticPopMany(self, count)

