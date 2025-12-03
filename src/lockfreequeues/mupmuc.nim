# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, multi-consumer (MPMC) bounded queue implemented as a ring buffer.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupmuc requires --threads:on option.".}

import atomics
import options

import ./ops
import ./mupsic
import ./sipsic


type NoConsumersAvailableError* = object of CatchableError ## \
  ## Raised by `getConsumer()` if all consumers have been assigned to other
  ## threads.


type
  Mupmuc*[N, P, C: static int, T] = object of Mupsic[N, P, T]
    ## A multi-producer, multi-consumer bounded queue implemented as a ring
    ## buffer.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `C` is the number of consumer threads.
    ## * `T` is the type of data the queue will hold.

    reservedHead* {.align: 64.}: Atomic[int]
      ## The next slot to be claimed by a consumer. Consumers CAS this
      ## to reserve slots. Uses a slot counter approach (not consumer ID)
      ## to avoid stale read race conditions.
    consumerThreadIds*: array[C, Atomic[int]] ## \
      ## Array of consumer thread IDs by index

  Consumer*[N, P, C: static int, T] = object
    ## A per-thread interface for popping items from a queue.
    ## Retrieved via a call to `Mupmuc.getConsumer()`
    idx*: int ## The consumer's unique identifier.
    queue*: ptr Mupmuc[N, P, C, T] ## A reference to the consumer's queue.

  MupmucProducer*[N, P, C: static int, T] = object
    ## A per-thread interface for pushing items to a Mupmuc queue.
    ## Uses reservedHead for fullness check to handle multi-consumer case.
    idx*: int ## The producer's unique identifier.
    queue*: ptr Mupmuc[N, P, C, T] ## A reference to the producer's queue.


proc clear[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T]
) =
  self.head.sequential(0)
  self.tail.sequential(0)
  self.reservedTail.sequential(0)
  self.reservedHead.sequential(0)

  for n in 0..<N:
    self.storage[n].reset()
    self.committed[n].store(false, moRelaxed)

  for p in 0..<P:
    self.producerThreadIds[p].sequential(0)

  for c in 0..<C:
    self.consumerThreadIds[c].sequential(0)


proc initMupmuc*[N, P, C: static int, T](): Mupmuc[N, P, C, T] =
  ## Initialize a new Mupmuc queue.
  result.clear()


proc getProducer*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  idx: int = -1,
): MupmucProducer[N, P, C, T]
  {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `MupmucProducer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> producerIdx
  for idx in 0..<P:
    if self.producerThreadIds[idx].acquire == threadId:
      result.idx = idx
      return

  # Try to create new mapping of threadId -> producerIdx
  for idx in 0..<P:
    var expected = 0
    if self.producerThreadIds[idx].compareExchangeWeak(
      expected,
      threadId,
      moRelease,
      moAcquire,
    ):
      result.idx = idx
      return

  # Producers are all spoken for by another thread
  raise newException(
    NoProducersAvailableError,
    "All producers have been assigned. " &
    "Increase your producer count (P) or setMaxPoolSize(P).")


proc push*[N, P, C: static int, T](
  self: MupmucProducer[N, P, C, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is lock-free: producers never block on each other.
  ## Uses reservedHead for fullness check to handle multi-consumer case.

  var slot: int
  var newReservedTail: int

  # Claim a slot using CAS on reservedTail
  while true:
    slot = self.queue.reservedTail.load(moAcquire)
    # Use reservedHead for fullness check (not head) because in multi-consumer
    # scenarios, head may be behind reservedHead due to out-of-order completion
    let reservedHead = self.queue.reservedHead.load(moAcquire)

    # Check if queue is full based on reservedHead/reservedTail distance
    if full(reservedHead, slot, N):
      return false

    newReservedTail = incOrReset(slot, 1, N)

    if self.queue.reservedTail.compareExchangeWeak(
      slot,
      newReservedTail,
      moRelease,
      moAcquire,
    ):
      break

  # Write the item to the claimed slot
  self.queue.storage[index(slot, N)] = item

  # Mark slot as committed (data ready to read)
  self.queue.committed[index(slot, N)].store(true, moRelease)

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
    # items is empty, nothing unpushed
    return NoSlice

  var actualCount: int
  var slot: int
  var newReservedTail: int

  # Claim slots using CAS on reservedTail
  while true:
    slot = self.queue.reservedTail.load(moAcquire)
    # Use reservedHead for fullness check (not head)
    let reservedHead = self.queue.reservedHead.load(moAcquire)

    # Check available slots based on reservedHead/reservedTail distance
    let avail = available(reservedHead, slot, N)

    if likely(avail >= items.len):
      # Enough room to push all items
      actualCount = items.len
    elif avail <= 0:
      # Queue is full, return
      return some(0..items.len - 1)
    else:
      # Not enough room to push all items
      actualCount = avail

    newReservedTail = incOrReset(slot, actualCount, N)

    if self.queue.reservedTail.compareExchangeWeak(
      slot,
      newReservedTail,
      moRelease,
      moAcquire,
    ):
      break

  if actualCount < items.len:
    # give back remainder
    result = some(actualCount..items.len - 1)
  else:
    result = NoSlice

  # Write items to claimed slots
  let start = index(slot, N)
  var stop = incOrReset(slot, actualCount - 1, N)
  stop = index(stop, N)

  if start > stop:
    # data may wrap
    let pivot = (N-1) - start
    self.queue.storage[start..start+pivot] = items[0..pivot]
    if stop > 0:
      # data wraps
      self.queue.storage[0..stop] = items[pivot+1..pivot+1+stop]
  else:
    # data does not wrap
    self.queue.storage[start..stop] = items[0..stop-start]

  # Mark all claimed slots as committed
  for i in 0..<actualCount:
    let idx = index(incOrReset(slot, i, N), N)
    self.queue.committed[idx].store(true, moRelease)


proc getConsumer*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  idx: int = -1,
): Consumer[N, P, C, T]
  {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  # getThreadId will be undeclared unless compiled with --threads:on
  let threadId = getThreadId()

  # Try to find existing mapping of threadId -> consumerIdx
  for idx in 0..<C:
    if self.consumerThreadIds[idx].acquire == threadId:
      result.idx = idx
      return

  # Try to create new mapping of threadId -> consumerIdx
  for idx in 0..<C:
    var expected = 0
    if self.consumerThreadIds[idx].compareExchangeWeak(
      expected,
      threadId,
      moRelease,
      moAcquire,
    ):
      result.idx = idx
      return

  # Consumers are all spoken for by another thread
  raise newException(
    NoConsumersAvailableError,
    "All consumers have been assigned. " &
    "Increase your consumer count (C) or setMaxPoolSize(min(C, P)).")


proc pop*[N, P, C: static int, T](
  self: Consumer[N, P, C, T],
): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## Otherwise an item is popped, `some(T)` is returned.
  ##
  ## This operation is lock-free.

  var slot: int
  var newReservedHead: int

  # Claim a slot using CAS on reservedHead
  while true:
    slot = self.queue.reservedHead.load(moAcquire)
    let reservedTail = self.queue.reservedTail.load(moAcquire)

    if unlikely(empty(slot, reservedTail, N)):
      return none(T)

    let slotIdx = index(slot, N)

    # Check if slot is committed BEFORE claiming
    if not self.queue.committed[slotIdx].load(moAcquire):
      return none(T)  # Producer still writing, try again later

    newReservedHead = incOrReset(slot, 1, N)

    if self.queue.reservedHead.compareExchangeWeak(
      slot,
      newReservedHead,
      moRelease,
      moAcquire,
    ):
      # Successfully claimed the slot
      # Read the item
      result = some(self.queue.storage[slotIdx])

      # Clear committed flag (slot can be reused by producer)
      self.queue.committed[slotIdx].store(false, moRelease)

      # Try to advance head (lock-free, may fail if other consumers are ahead)
      var expectedHead = slot
      discard self.queue.head.compareExchangeWeak(
        expectedHead,
        newReservedHead,
        moRelease,
        moAcquire,
      )
      return


proc pop*[N, P, C: static int, T](
  self: Consumer[N, P, C, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one item.
  ##
  ## This operation is lock-free.

  if unlikely(count <= 0):
    return none(seq[T])

  var actualCount: int
  var slot: int
  var newReservedHead: int

  # Claim slots using CAS on reservedHead
  while true:
    slot = self.queue.reservedHead.load(moAcquire)
    let reservedTail = self.queue.reservedTail.load(moAcquire)

    if unlikely(empty(slot, reservedTail, N)):
      return none(seq[T])

    # Count available committed slots
    var avail = 0
    for i in 0..<min(count, N):
      let idx = index(incOrReset(slot, i, N), N)
      if not self.queue.committed[idx].load(moAcquire):
        break  # Hit an uncommitted slot, stop
      inc avail

    if avail <= 0:
      return none(seq[T])  # No committed items available

    actualCount = min(avail, count)
    newReservedHead = incOrReset(slot, actualCount, N)

    if self.queue.reservedHead.compareExchangeWeak(
      slot,
      newReservedHead,
      moRelease,
      moAcquire,
    ):
      break

  # Read items from claimed slots
  let start = index(slot, N)
  var stop = incOrReset(slot, actualCount - 1, N)
  stop = index(stop, N)

  var items = newSeq[T](actualCount)

  if start > stop:
    # data may wrap
    let pivot = (N-1) - start
    items[0..pivot] = self.queue.storage[start..start+pivot]
    if stop > 0:
      # data wraps
      items[pivot+1..pivot+1+stop] = self.queue.storage[0..stop]
  else:
    # data does not wrap
    items[0..stop-start] = self.queue.storage[start..stop]

  result = some(items)

  # Clear committed flags for all claimed slots (signals producer they're free)
  for i in 0..<actualCount:
    let idx = index(incOrReset(slot, i, N), N)
    self.queue.committed[idx].store(false, moRelease)

  # Try to advance head (lock-free, may fail if other consumers are ahead)
  var expectedHead = slot
  discard self.queue.head.compareExchangeWeak(
    expectedHead,
    newReservedHead,
    moRelease,
    moAcquire,
  )


proc pop*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
): bool =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc pop*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  count: int,
): Option[seq[T]] =
  ## Raises `InvalidCallDefect`. Use `Consumer.pop()` instead.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc consumerCount*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
): int
  {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C


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


when defined(testing):
  from unittest import check

  proc reset*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T]
  ) =
    ## Resets the queue to its default state.
    self.clear()

  proc checkState*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T],
    head: int,
    reservedHead: int,
    tail: int,
  ) =
    ## Check internal queue state for testing.
    check(self.head.sequential == head)
    check(self.reservedHead.sequential == reservedHead)
    check(self.tail.sequential == tail)
