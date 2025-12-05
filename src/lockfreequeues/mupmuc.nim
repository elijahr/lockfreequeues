# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, multi-consumer (MPMC) bounded queue.
##
## Both push and pop are lock-free (producers coordinate via CAS, consumers
## coordinate via CAS, with committed flags for synchronization).

when not compileOption("threads"):
  {.error: "lockfreequeues/mupmuc requires --threads:on option.".}

import atomics
import options

import ./constants
import ./exceptions
import ./typestates
import ./typestates/mpmc_pop

export exceptions

const NoSlice* = none(HSlice[int, int])

type
  Mupmuc*[N, P, C: static int, T] = object
    ## A multi-producer, multi-consumer bounded queue.
    ## Uses N slots + committed flags. Both push and pop are lock-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `C` is the number of consumer threads.
    ## * `T` is the type of data the queue will hold.

    head* {.align: CacheLineBytes.}: Atomic[int]
    reservedHead* {.align: CacheLineBytes.}: Atomic[int]
    reservedTail* {.align: CacheLineBytes.}: Atomic[int]
    storage*: StorageN[N, T]
    committed*: CommittedFlagsN[N]
    producerThreadIds*: array[P, Atomic[int]]
    consumerThreadIds*: array[C, Atomic[int]]

  MupmucProducer*[N, P, C: static int, T] = object
    ## A per-thread interface for pushing items to a Mupmuc queue.
    idx*: int
    queue*: ptr Mupmuc[N, P, C, T]

  Consumer*[N, P, C: static int, T] = object
    ## A per-thread interface for popping items from a Mupmuc queue.
    idx*: int
    queue*: ptr Mupmuc[N, P, C, T]


proc clear[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]) =
  self.head.store(0, moRelaxed)
  self.reservedHead.store(0, moRelaxed)
  self.reservedTail.store(0, moRelaxed)
  self.storage.init()
  self.committed.init()
  for p in 0..<P:
    self.producerThreadIds[p].store(0, moRelaxed)
  for c in 0..<C:
    self.consumerThreadIds[c].store(0, moRelaxed)


proc initMupmuc*[N, P, C: static int, T](): Mupmuc[N, P, C, T] =
  ## Initialize a new Mupmuc queue.
  result.clear()


proc getProducer*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  idx: int = -1,
): MupmucProducer[N, P, C, T] {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `MupmucProducer` instance for the current thread.
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


proc getConsumer*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  idx: int = -1,
): Consumer[N, P, C, T] {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> consumerIdx
  for i in 0..<C:
    if self.consumerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  # Try to create new mapping of threadId -> consumerIdx
  for i in 0..<C:
    var expected = 0
    if self.consumerThreadIds[i].compareExchangeWeak(
      expected,
      threadId,
      moRelease,
      moAcquire,
    ):
      result.idx = i
      return

  # Consumers are all spoken for by another thread
  raise newException(
    NoConsumersAvailableError,
    "All consumers have been assigned. " &
    "Increase your consumer count (C) or setMaxPoolSize(min(C, P)).")


proc push*[N, P, C: static int, T](
  self: MupmucProducer[N, P, C, T],
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
    # MPMC KEY: Use reservedHead (not head) because consumers can lag
    let reservedHead = loadAcquireN[N](self.queue.reservedHead).validate()

    # MPMC: uses reservedHead vs reservedTail (both can lag)
    if unlikely(fullN(reservedHead, reservedTail)):
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
  self.queue.committed.store(slot, true)

  return true


proc push*[N, P, C: static int, T](
  self: MupmucProducer[N, P, C, T],
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
    # MPMC KEY: Use reservedHead (not head)
    let reservedHead = loadAcquireN[N](self.queue.reservedHead).validate()

    # MPMC: uses reservedHead vs reservedTail
    if unlikely(fullN(reservedHead, reservedTail)):
      return some(0..items.len - 1)

    let avail = availableN(reservedHead, reservedTail)

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


proc pop*[N, P, C: static int, T](
  self: Consumer[N, P, C, T],
): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped, `some(T)` is returned.
  ##
  ## This operation is lock-free: consumers never block on each other.
  ## Uses typestate to ensure correct operation sequencing.

  # Cast queue to MupmucBase for typestate compatibility
  var queueBase = cast[ptr MupmucBase[N, P, C, T]](self.queue)

  var op = mpmc_pop.start[N]()

  while true:
    let loaded = op.loadPointers(queueBase[])

    let emptyCheck = loaded.checkEmpty()
    case emptyCheck.kind:
    of mMPMCPopEmpty:
      return none(T)
    of mMPMCPopNotEmpty:
      let notEmpty = emptyCheck.mpmcpopnotempty
      let committedCheck = notEmpty.checkCommitted(queueBase[])
      case committedCheck.kind:
      of mMPMCPopStart:
        op = committedCheck.mpmcpopstart  # Retry - producer still writing
        continue
      of mMPMCPopSlotReady:
        let ready = committedCheck.mpmcpopslotready
        let claimResult = ready.tryClaim(queueBase[])
        case claimResult.kind:
        of mMPMCPopStart:
          op = claimResult.mpmcpopstart  # Retry - CAS contention
          continue
        of mMPMCPopSlotClaimed:
          let claimed = claimResult.mpmcpopslotclaimed
          return some(claimed.complete(queueBase[]))


proc pop*[N, P, C: static int, T](
  self: Consumer[N, P, C, T],
  count: int,
): Option[seq[T]] =
  ## Pop up to `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one item.
  ##
  ## This operation is lock-free: consumers never block on each other.

  if unlikely(count <= 0):
    return none(seq[T])

  var actualCount: int
  var reservedHead: WrappedValueN[N]
  var newReservedHead: WrappedValueN[N]

  # Claim slots using CAS on reservedHead
  while true:
    reservedHead = loadAcquireN[N](self.queue.reservedHead).validate()
    let reservedTail = loadAcquireN[N](self.queue.reservedTail).validate()

    if unlikely(emptyN(reservedHead, reservedTail)):
      return none(seq[T])

    # Count available committed slots
    var avail = 0
    for i in 0..<min(count, N):
      let idx = reservedHead.incOrResetN(i).index()
      if not self.queue.committed.load(idx):
        break  # Hit an uncommitted slot, stop
      inc avail

    if avail <= 0:
      return none(seq[T])  # No committed items available

    actualCount = min(avail, count)
    newReservedHead = reservedHead.incOrResetN(actualCount)

    let cas = prepareCAS(
      addr self.queue.reservedHead,
      reservedHead.value,
      newReservedHead.value
    ).executeCAS()

    if cas.succeeded:
      break

  # Read each slot
  var items = newSeq[T](actualCount)
  for i in 0..<actualCount:
    let currentHead = reservedHead.incOrResetN(i)
    items[i] = self.queue.storage[currentHead.index()]

  result = some(items)

  # Clear committed flags for all claimed slots
  for i in 0..<actualCount:
    let idx = reservedHead.incOrResetN(i).index()
    self.queue.committed.store(idx, false)

  # Try to advance head (lock-free, may fail if other consumers are ahead)
  var expectedHead = reservedHead.value
  discard self.queue.head.compareExchangeWeak(
    expectedHead,
    newReservedHead.value,
    moRelease,
    moAcquire,
  )


proc push*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  item: T,
): bool =
  ## Raises `InvalidCallDefect`. Use `MupmucProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use MupmucProducer.push()")


proc push*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Raises `InvalidCallDefect`. Use `MupmucProducer.push()` instead.
  raise newException(InvalidCallDefect, "Use MupmucProducer.push()")


proc pop*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
): Option[T] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc pop*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  count: int,
): Option[seq[T]] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc capacity*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]): int {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N


proc producerCount*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]): int {.inline.} =
  ## Returns the queue's number of producers (`P`).
  result = P


proc consumerCount*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]): int {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C


when defined(testing):
  from unittest import check

  proc reset*[N, P, C: static int, T](self: var Mupmuc[N, P, C, T]) =
    ## Resets the queue to its default state.
    ## For single-threaded unit tests only.
    self.clear()

  proc checkState*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T],
    head: int,
    reservedHead: int,
    tail: int,
  ) =
    ## Check internal queue state for testing.
    check(self.head.load(moRelaxed) == head)
    check(self.reservedHead.load(moRelaxed) == reservedHead)
    check(self.reservedTail.load(moRelaxed) == tail)

  proc checkState*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T],
    head: int,
    reservedTail: int,
  ) =
    ## Check internal queue state for testing (simplified, just head and reservedTail).
    check(self.head.load(moRelaxed) == head)
    check(self.reservedTail.load(moRelaxed) == reservedTail)

  proc checkState*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T],
    head: int,
    tail: int,
    storage: seq[T],
  ) =
    ## Check internal queue state for testing (simplified, without reservedHead).
    check(self.head.load(moRelaxed) == head)
    check(self.reservedTail.load(moRelaxed) == tail)
    for i in 0..<N:
      check(self.storage.data[i] == storage[i])
