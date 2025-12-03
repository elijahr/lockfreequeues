# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, single-consumer (MPSC) bounded queue implemented as a ring buffer.
##
## Push is lock-free for multiple producers (CAS coordination with committed flags).
## Pop is wait-free for the single consumer.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupsic requires --threads:on option.".}

import atomics
import options

import ./atomic_dsl
import ./ops
import ./sipsic


type NoProducersAvailableError* = object of CatchableError ## \
  ## Raised by `getProducer()` if all producers have been assigned to other
  ## threads.

type InvalidCallDefect* = object of Defect ## \
  ## Raised by `Mupsic.push()`, `Mupmuc.push()`, and `Mupmuc.pop()` because
  ## those should happen via `Producer.push()` or `Consumer.pop()`.

type
  Mupsic*[N, P: static int, T] = object of Sipsic[N, T]
    ## A multi-producer, single-consumer bounded queue implemented as a ring
    ## buffer. Push is lock-free. Pop is wait-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `T` is the type of data the queue will hold.

    reservedTail* {.align: 64.}: Atomic[int]
      ## The next slot to be claimed by a producer. Producers CAS this
      ## to reserve slots.
    committed*: array[N, Atomic[bool]]
      ## Per-slot commit flags. Set by producer after writing data.
      ## Checked by consumer before reading. Enables lock-free push.
    producerThreadIds*: array[P, Atomic[int]]
      ## Array of producer thread IDs by index.

  Producer*[N, P: static int, T] = object
    ## A per-thread interface for pushing items to a queue.
    ## Retrieved via a call to `Mupsic.getProducer()`
    idx*: int ## The producer's unique identifier.
    queue*: ptr Mupsic[N, P, T] ## A reference to the producer's queue.


proc clear[N, P: static int, T](
  self: var Mupsic[N, P, T]
) =
  self.head.sequential(0)
  self.tail.sequential(0)
  self.reservedTail.sequential(0)

  for n in 0..<N:
    self.storage[n].reset()
    self.committed[n].store(false, moRelaxed)

  for p in 0..<P:
    self.producerThreadIds[p].sequential(0)


proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] =
  ## Initialize a new Mupsic queue.
  result.clear()


proc getProducer*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  idx: int = -1,
): Producer[N, P, T]
  {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `Producer` instance for the current thread.
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


proc push*[N, P: static int, T](
  self: Producer[N, P, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is lock-free: producers never block on each other.

  var slot: int
  var newReservedTail: int

  # Claim a slot using CAS on reservedTail
  while true:
    slot = self.queue.reservedTail.load(moAcquire)
    let head = self.queue.head.load(moAcquire)

    # Check if queue is full based on head/tail distance
    # This prevents wraparound race where a producer could claim a slot
    # that another producer is still writing to
    if full(head, slot, N):
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
  # No ordered wait - this is what makes push lock-free
  self.queue.committed[index(slot, N)].store(true, moRelease)

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
    # items is empty, nothing unpushed
    return NoSlice

  var actualCount: int
  var slot: int
  var newReservedTail: int

  # Claim slots using CAS on reservedTail
  while true:
    slot = self.queue.reservedTail.load(moAcquire)
    let head = self.queue.head.load(moAcquire)

    # Check available slots based on head/tail distance
    # This prevents wraparound race where a producer could claim slots
    # that other producers are still writing to
    let avail = available(head, slot, N)

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
  # No ordered wait - this is what makes push lock-free
  for i in 0..<actualCount:
    let idx = index(incOrReset(slot, i, N), N)
    self.queue.committed[idx].store(true, moRelease)


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
  let head = self.head.load(moAcquire)
  let reservedTail = self.reservedTail.load(moAcquire)

  # Check if anything has been claimed
  if unlikely(empty(head, reservedTail, N)):
    return none(T)

  let headIdx = index(head, N)

  # Check if head slot is committed (data ready to read)
  if not self.committed[headIdx].load(moAcquire):
    return none(T)  # Producer still writing

  result = some(self.storage[headIdx])

  # Clear committed flag for slot reuse
  self.committed[headIdx].store(false, moRelease)

  let newHead = incOrReset(head, 1, N)
  self.head.store(newHead, moRelease)


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

  let head = self.head.load(moAcquire)
  let reservedTail = self.reservedTail.load(moAcquire)

  let available = used(head, reservedTail, N)
  if available <= 0:
    return none(seq[T])

  # Pop items until we hit an uncommitted slot or reach count
  var items = newSeq[T]()
  var currentHead = head

  for i in 0..<min(count, available):
    let idx = index(currentHead, N)

    # Check if this slot is committed
    if not self.committed[idx].load(moAcquire):
      break  # Stop at first uncommitted slot

    items.add(self.storage[idx])

    # Clear committed flag for slot reuse
    self.committed[idx].store(false, moRelease)

    currentHead = incOrReset(currentHead, 1, N)

  if items.len == 0:
    return none(seq[T])

  self.head.store(currentHead, moRelease)
  return some(items)


proc capacity*[N, P: static int, T](
  self: var Mupsic[N, P, T],
): int
  {.inline.} =
  ## Returns the queue's storage capacity (`N`).
  result = N


proc producerCount*[N, P: static int, T](
  self: var Mupsic[N, P, T],
): int
  {.inline.} =
  ## Returns the queue's number of producers (`P`).
  result = P

when defined(testing):
  from unittest import check

  proc reset*[N, P: static int, T](
    self: var Mupsic[N, P, T]
  ) =
    ## Resets the queue to its default state.
    ## For single-threaded unit tests only.
    self.clear()

  proc checkState*[N, P: static int, T](
    self: var Mupsic[N, P, T],
    head: int,
    reservedTail: int,
  ) =
    ## Check internal queue state for testing.
    ## Note: tail is no longer used; committed flags track readiness.
    check(self.head.sequential == head)
    check(self.reservedTail.sequential == reservedTail)
