import atomics

import ./atomic_dsl

type
  Queue* = concept q, type Q
    q.head is Atomic[SomeInteger]
    q.tail is Atomic[SomeInteger]
    type ItemType = Q.itemType

  StaticQueue*[N: static int, T] = concept q, type Q
    Q is Queue
    q.storage is array[N, T]
    type ItemType = Q.itemType

  SharedQueue*[T] = concept q, type Q
    Q is Queue
    q.capacity is SomeInteger
    q.storage is ptr UncheckedArray[T]
    type ItemType = Q.itemType

  MupStaticQueue*[P: static int] = concept q, type Q
    Q is StaticQueue
    type PrevPidType = Atomic[SomeInteger]
    type ProducersType = array[P, PackedAtomic[Producer, SomeOrdinal]]
    q.prevPid is PrevPidType
    q.producers is ProducersType
    type ItemType = Q.itemType


proc capacity*[N: static int, T](
  self: StaticQueue[N, T],
):
  static int
  {.inline.} =
  ## Return the queue's capacity.
  return N


proc producerCount*[P: static int](
  self: MupStaticQueue[P],
):
  static int
  {.inline.} =
  ## Return the queue's producer count.
  return P
