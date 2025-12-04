# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, multi-consumer (SPMC) bounded queue.
##
## Sipmuc provides wait-free push operations (single producer) and lock-free
## pop operations (multiple consumers coordinate via CAS).

when not compileOption("threads"):
  {.error: "lockfreequeues/sipmuc requires --threads:on option.".}

import atomics
import options

import ./constants
import ./exceptions
import ./typestates

const NoSlice* = none(HSlice[int, int])

type
  Sipmuc*[N, C: static int, T] = object
    ## A single-producer, multi-consumer (SPMC) bounded queue.
    ## Uses N slots with committed flags.
    ##
    ## * `N` is the capacity (number of items that can be stored).
    ## * `C` is the number of consumer threads.
    ## * `T` is the type of data the queue will hold.
    head* {.align: CacheLineBytes.}: Atomic[int]
    reservedHead* {.align: CacheLineBytes.}: Atomic[int]
    tail* {.align: CacheLineBytes.}: Atomic[int]
    storage*: StorageN[N, T]
    committed*: CommittedFlagsN[N]
    consumerThreadIds*: array[C, Atomic[int]]

  Consumer*[N, C: static int, T] = object
    idx*: int
    queue*: ptr Sipmuc[N, C, T]


proc clear[N, C: static int, T](self: var Sipmuc[N, C, T]) =
  self.head.store(0, moRelaxed)
  self.tail.store(0, moRelaxed)
  self.reservedHead.store(0, moRelaxed)
  self.storage.init()
  self.committed.init()
  for c in 0..<C:
    self.consumerThreadIds[c].store(0, moRelaxed)


proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T] =
  ## Initialize a new Sipmuc queue.
  result.clear()


proc consumerCount*[N, C: static int, T](self: var Sipmuc[N, C, T]): int {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C


proc capacity*[N, C: static int, T](self: var Sipmuc[N, C, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N


proc push*[N, C: static int, T](self: var Sipmuc[N, C, T], item: T): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is wait-free for the single producer.

  # Load pointers with proper memory ordering
  let tail = loadAcquireN[N](self.tail).validate()
  # KEY FIX: SPMC uses reservedHead vs tail for fullness check!
  let reservedHead = loadAcquireN[N](self.reservedHead).validate()

  # Check fullness using SPMC formula (reservedHead, not head)
  if unlikely(fullN(reservedHead, tail)):
    return false

  # Write to storage using type-safe slot
  let slot = tail.index()
  self.storage[slot] = item

  # Mark committed first, then advance tail
  self.committed.store(slot, true)

  # Advance tail
  let newTail = tail.incOrResetN(1)
  self.tail.storeReleaseN(newTail)

  return true


proc push*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  if unlikely(items.len == 0):
    return NoSlice

  let tail = loadAcquireN[N](self.tail).validate()
  let reservedHead = loadAcquireN[N](self.reservedHead).validate()

  if unlikely(fullN(reservedHead, tail)):
    return some(0..items.len - 1)

  let avail = availableN(reservedHead, tail)
  var count: int

  if likely(avail >= items.len):
    result = NoSlice
    count = items.len
  else:
    result = some(avail..items.len - 1)
    count = min(avail, N)

  # Write each item
  for i in 0..<count:
    let currentTail = tail.incOrResetN(i)
    self.storage[currentTail.index()] = items[i]

  # Mark all committed
  for i in 0..<count:
    let slot = tail.incOrResetN(i).index()
    self.committed.store(slot, true)

  let newTail = tail.incOrResetN(count)
  self.tail.storeReleaseN(newTail)


proc getConsumer*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  idx: int = -1,
): Consumer[N, C, T] {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  let threadId = getThreadId()

  # Try to find existing mapping
  for i in 0..<C:
    if self.consumerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping
  for i in 0..<C:
    var expected = 0
    if self.consumerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  raise newException(NoConsumersAvailableError, "All consumers assigned")


proc pop*[N, C: static int, T](self: Consumer[N, C, T]): Option[T] =
  ## Pop a single item from the queue.
  ##
  ## This operation is lock-free: consumers never block on each other.
  var reservedHead: WrappedValueN[N]
  var newReservedHead: WrappedValueN[N]

  # Claim a slot using CAS on reservedHead
  while true:
    reservedHead = loadAcquireN[N](self.queue.reservedHead).validate()
    let tail = loadAcquireN[N](self.queue.tail).validate()

    # SPMC: uses reservedHead vs tail
    if unlikely(emptyN(reservedHead, tail)):
      return none(T)

    newReservedHead = reservedHead.incOrResetN(1)

    var expected = reservedHead.value
    if self.queue.reservedHead.compareExchangeWeak(
      expected,
      newReservedHead.value,
      moRelease,
      moAcquire,
    ):
      break

  let slot = reservedHead.index()

  # Check committed
  if not self.queue.committed.load(slot):
    return none(T)

  result = some(self.queue.storage[slot])

  # Clear committed
  self.queue.committed.store(slot, false)

  # Fire-and-forget head advance (best effort)
  var expectedHead = reservedHead.value
  discard self.queue.head.compareExchangeWeak(
    expectedHead,
    newReservedHead.value,
    moRelease,
    moAcquire,
  )


proc pop*[N, C: static int, T](
  self: Consumer[N, C, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  if unlikely(count <= 0):
    return none(seq[T])

  var items = newSeq[T]()

  for _ in 0..<count:
    let item = self.pop()
    if item.isNone:
      break
    items.add(item.get())

  if items.len == 0:
    return none(seq[T])

  return some(items)


proc pop*[N, C: static int, T](self: var Sipmuc[N, C, T]): Option[T] =
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc pop*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  count: int,
): Option[seq[T]] =
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


when defined(testing):
  from unittest import check

  proc reset*[N, C: static int, T](self: var Sipmuc[N, C, T]) =
    self.clear()

  proc checkState*[N, C: static int, T](
    self: var Sipmuc[N, C, T],
    head: int,
    reservedHead: int,
    tail: int,
  ) =
    check(self.head.load(moRelaxed) == head)
    check(self.reservedHead.load(moRelaxed) == reservedHead)
    check(self.tail.load(moRelaxed) == tail)

  proc checkState*[N, C: static int, T](
    self: var Sipmuc[N, C, T],
    head: int,
    tail: int,
    storage: seq[T],
  ) =
    check(self.head.load(moRelaxed) == head)
    check(self.tail.load(moRelaxed) == tail)
    for i in 0..<N:
      check(self.storage.data[i] == storage[i])
