# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, single-consumer (MPSC) bounded queue.
##
## Push is lock-free for multiple producers (CAS coordination with committed flags).
## Pop is wait-free for the single consumer.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupsic requires --threads:on option.".}

import atomics
import options

import ./constants
import ./typestates

const NoSlice* = none(HSlice[int, int])

type NoProducersAvailableError* = object of CatchableError
  ## Raised by `getProducer()` if all producers have been assigned to other threads.

type InvalidCallDefect* = object of Defect
  ## Raised by `Mupsic.push()` because push should happen via `Producer.push()`.

type
  Mupsic*[N, P: static int, T] = object of RootObj
    ## A multi-producer, single-consumer bounded queue.
    ## Uses N slots + committed flags. Push is lock-free. Pop is wait-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `T` is the type of data the queue will hold.

    head* {.align: CacheLineBytes.}: Atomic[int]
    reservedTail* {.align: CacheLineBytes.}: Atomic[int]
    storage*: StorageN[N, T]
    committed*: CommittedFlagsN[N]
    producerThreadIds*: array[P, Atomic[int]]

  Producer*[N, P: static int, T] = object
    ## A per-thread interface for pushing items to a queue.
    ## Retrieved via a call to `Mupsic.getProducer()`
    idx*: int
    queue*: ptr Mupsic[N, P, T]


proc clear[N, P: static int, T](self: var Mupsic[N, P, T]) =
  self.head.store(0, moRelaxed)
  self.reservedTail.store(0, moRelaxed)
  self.storage.init()
  self.committed.init()
  for p in 0..<P:
    self.producerThreadIds[p].store(0, moRelaxed)


proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] =
  ## Initialize a new Mupsic queue.
  result.clear()


proc getProducer*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  idx: int = -1,
): Producer[N, P, T] {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `Producer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> producerIdx
  for i in 0..<P:
    if self.producerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping of threadId -> producerIdx
  for i in 0..<P:
    var expected = 0
    if self.producerThreadIds[i].compareExchangeWeak(
      expected,
      threadId,
      moRelease,
      moAcquire,
    ):
      result.idx = i
      return

  # Producers are all spoken for by another thread
  raise newException(
    NoProducersAvailableError,
    "All producers have been assigned. " &
    "Increase your producer count (P) or setMaxPoolSize(P).")


proc push*[N, P: static int, T](
  self: Producer[N, P, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is lock-free: producers never block on each other.

  var reservedTail: WrappedValueN[N]
  var newReservedTail: WrappedValueN[N]

  # Claim a slot using CAS on reservedTail
  while true:
    reservedTail = loadAcquireN[N](self.queue.reservedTail).validate()
    let head = loadAcquireN[N](self.queue.head).validate()

    # MPSC: uses head vs reservedTail (single consumer, head is current)
    if unlikely(fullN(head, reservedTail)):
      return false

    newReservedTail = reservedTail.incOrResetN(1)

    let cas = prepareCAS(
      addr self.queue.reservedTail,
      reservedTail.value,
      newReservedTail.value
    ).executeCAS()

    if cas.succeeded:
      break

  # Write the item to the claimed slot
  let slot = reservedTail.index()
  self.queue.storage[slot] = item

  # Mark slot as committed (data ready to read)
  # No ordered wait - this is what makes push lock-free
  self.queue.committed.store(slot, true)

  return true


proc push*[N, P: static int, T](
  self: Producer[N, P, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `none(HSlice[int, int])` is returned.
  ##
  ## This operation is lock-free: producers never block on each other.
  if unlikely(items.len == 0):
    return NoSlice

  var actualCount: int
  var reservedTail: WrappedValueN[N]
  var newReservedTail: WrappedValueN[N]

  # Claim slots using CAS on reservedTail
  while true:
    reservedTail = loadAcquireN[N](self.queue.reservedTail).validate()
    let head = loadAcquireN[N](self.queue.head).validate()

    # MPSC: uses head vs reservedTail (single consumer, head is current)
    if unlikely(fullN(head, reservedTail)):
      return some(0..items.len - 1)

    let avail = availableN(head, reservedTail)

    if likely(avail >= items.len):
      actualCount = items.len
    else:
      actualCount = min(avail, N)

    newReservedTail = reservedTail.incOrResetN(actualCount)

    let cas = prepareCAS(
      addr self.queue.reservedTail,
      reservedTail.value,
      newReservedTail.value
    ).executeCAS()

    if cas.succeeded:
      break

  if actualCount < items.len:
    result = some(actualCount..items.len - 1)
  else:
    result = NoSlice

  # Write each item
  for i in 0..<actualCount:
    let currentTail = reservedTail.incOrResetN(i)
    self.queue.storage[currentTail.index()] = items[i]

  # Mark all claimed slots as committed
  for i in 0..<actualCount:
    let slot = reservedTail.incOrResetN(i).index()
    self.queue.committed.store(slot, true)


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  item: T,
): bool =
  ## Raises `InvalidCallDefect`. Use `Producer.push()` instead.
  raise newException(InvalidCallDefect, "Use Producer.push()")


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Raises `InvalidCallDefect`. Use `Producer.push()` instead.
  raise newException(InvalidCallDefect, "Use Producer.push()")


proc pop*[N, P: static int, T](
  self: var Mupsic[N, P, T],
): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty or head slot is not yet committed, `none(T)` is returned.
  ## Otherwise an item is popped, `some(T)` is returned.
  ##
  ## This operation is wait-free for the single consumer.
  let head = loadAcquireN[N](self.head).validate()
  let reservedTail = loadAcquireN[N](self.reservedTail).validate()

  # Check if anything has been claimed
  if unlikely(emptyN(head, reservedTail)):
    return none(T)

  let slot = head.index()

  # Check if head slot is committed (data ready to read)
  if not self.committed.load(slot):
    return none(T)  # Producer still writing

  result = some(self.storage[slot])

  # Clear committed flag for slot reuse
  self.committed.store(slot, false)

  let newHead = head.incOrResetN(1)
  self.head.storeReleaseN(newHead)


proc pop*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  count: int,
): Option[seq[T]] =
  ## Pop up to `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one item.
  ## May return fewer items than requested if some slots are not yet committed.
  ##
  ## This operation is wait-free for the single consumer.
  if unlikely(count <= 0):
    return none(seq[T])

  let head = loadAcquireN[N](self.head).validate()
  let reservedTail = loadAcquireN[N](self.reservedTail).validate()

  let usedCount = usedN(head, reservedTail)
  if usedCount <= 0:
    return none(seq[T])

  # Pop items until we hit an uncommitted slot or reach count
  var items = newSeq[T]()
  var currentHead = head

  for i in 0..<min(count, usedCount):
    let slot = currentHead.index()

    # Check if this slot is committed
    if not self.committed.load(slot):
      break  # Stop at first uncommitted slot

    items.add(self.storage[slot])

    # Clear committed flag for slot reuse
    self.committed.store(slot, false)

    currentHead = currentHead.incOrResetN(1)

  if items.len == 0:
    return none(seq[T])

  self.head.storeReleaseN(currentHead)
  return some(items)


proc capacity*[N, P: static int, T](self: var Mupsic[N, P, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N


proc producerCount*[N, P: static int, T](self: var Mupsic[N, P, T]): int {.inline.} =
  ## Returns the queue's number of producers (`P`).
  result = P


when defined(testing):
  from unittest import check

  proc reset*[N, P: static int, T](self: var Mupsic[N, P, T]) =
    ## Resets the queue to its default state.
    ## For single-threaded unit tests only.
    self.clear()

  proc checkState*[N, P: static int, T](
    self: var Mupsic[N, P, T],
    head: int,
    reservedTail: int,
  ) =
    ## Check internal queue state for testing.
    check(self.head.load(moRelaxed) == head)
    check(self.reservedTail.load(moRelaxed) == reservedTail)
