## A single-producer, single-consumer (SPSC) bounded queue implemented as a
## ring buffer.

import ./atomic_dsl
import options

import ./typestates
import ./typestates/spsc_push
import ./typestates/spsc_pop

const NoSlice* = none(HSlice[int, int])

type Sipsic*[N: static int, T] = object
  ## A single-producer, single-consumer (SPSC) bounded queue.
  ## Uses N+1 slots to distinguish full from empty.
  ##
  ## * `N` is the capacity (number of items that can be stored).
  ## * `T` is the type of data the queue will hold.
  head* {.align: CacheLineBytes.}: Atomic[int]
  tail* {.align: CacheLineBytes.}: Atomic[int]
  storage*: StorageN1[N, T]

proc clear[N: static int, T](self: var Sipsic[N, T]) =
  self.head.store(0, moRelaxed)
  self.tail.store(0, moRelaxed)
  self.storage.init()

proc initSipsic*[N: static int, T](): Sipsic[N, T] =
  ## Initialize a new Sipsic queue.
  result.clear()

proc push*[N: static int, T](self: var Sipsic[N, T], item: T): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## Uses typestate to ensure correct operation sequencing.

  # Cast queue to SipsicBase for typestate compatibility
  var queueBase = cast[ptr SipsicBase[N, T]](addr self)

  let op = spsc_push.start[N]()
  let loaded = op.loadPointers(queueBase[])
  var fullCheck = loaded.checkFull()

  match fullCheck:
    SPSCPushFull(full):
      return full.extractFalse()
    SPSCPushNotFull(notFull):
      return notFull.writeData(queueBase[], item).complete(queueBase[])

proc push*[N: static int, T](
    self: var Sipsic[N, T], items: openArray[T]
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  ## Batch push doesn't use typestate yet - uses inline implementation.
  if unlikely(items.len == 0):
    return NoSlice

  let tail = loadAcquireN1[N](self.tail).validate()
  let head = loadSequentialN1[N](self.head).validate()

  if unlikely(fullN1(head, tail)):
    return some(0 .. items.len - 1)

  let avail = availableN1(head, tail)
  var count: int

  if likely(avail >= items.len):
    result = NoSlice
    count = items.len
  else:
    result = some(avail .. items.len - 1)
    count = min(avail, N)

  # Write each item
  for i in 0 ..< count:
    let currentTail = tail.incOrResetN1(i)
    self.storage[currentTail.index()] = items[i]

  let newTail = tail.incOrResetN1(count)
  self.tail.storeReleaseN1(newTail)

proc pop*[N: static int, T](self: var Sipsic[N, T]): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped, `some(T)` is returned.
  ##
  ## Uses typestate to ensure correct operation sequencing.

  # Cast queue to SipsicBase for typestate compatibility
  var queueBase = cast[ptr SipsicBase[N, T]](addr self)

  let op = spsc_pop.start[N]()
  let loaded = op.loadPointers(queueBase[])
  var emptyCheck = loaded.checkEmpty()

  match emptyCheck:
    SPSCPopEmpty(_):
      return none(T)
    SPSCPopNotEmpty(notEmpty):
      return some(notEmpty.complete(queueBase[]))

proc pop*[N: static int, T](self: var Sipsic[N, T], count: int): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## Batch pop doesn't use typestate yet - uses inline implementation.
  let head = loadAcquireN1[N](self.head).validate()
  let tail = loadSequentialN1[N](self.tail).validate()

  let usedCount = usedN1(head, tail)
  var actualCount: int

  if likely(usedCount >= count):
    actualCount = count
  elif usedCount <= 0:
    return none(seq[T])
  else:
    actualCount = min(usedCount, N)

  var res = newSeq[T](actualCount)

  for i in 0 ..< actualCount:
    let currentHead = head.incOrResetN1(i)
    res[i] = self.storage[currentHead.index()]

  result = some(res)
  let newHead = head.incOrResetN1(actualCount)
  self.head.storeReleaseN1(newHead)

proc capacity*[N: static int, T](self: var Sipsic[N, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N

when defined(testing):
  from unittest import check

  proc reset*[N: static int, T](self: var Sipsic[N, T]) =
    self.clear()

  proc checkState*[N: static int, T](
      self: var Sipsic[N, T], head: int, tail: int, storage: seq[T]
  ) =
    ## Verify queue state. `storage` contains N+1 elements representing
    ## the physical slot contents (indices 0..N).
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0 .. N:
      if i < storage.len:
        check(self.storage.data[i] == storage[i])
