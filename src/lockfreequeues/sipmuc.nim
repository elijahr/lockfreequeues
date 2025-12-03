# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, multi-consumer (SPMC) bounded queue implemented as a ring buffer.
##
## Sipmuc provides wait-free push operations (single producer) and lock-free
## pop operations (multiple consumers coordinate via CAS).
##
## - N: The capacity of the queue (static, compile-time).
## - C: The number of consumer threads (static, compile-time).
## - T: The type of data the queue will hold.

when not compileOption("threads"):
  {.error: "lockfreequeues/sipmuc requires --threads:on option.".}

import atomics
import options

import ./atomic_dsl
import ./mupsic
import ./ops
import ./sipsic


type NoConsumersAvailableError* = object of CatchableError
  ## Raised by `getConsumer()` if all consumers have been assigned to other
  ## threads.


type
  Sipmuc*[N, C: static int, T] = object of Sipsic[N, T]
    ## A single-producer, multi-consumer (SPMC) bounded queue implemented as a
    ## ring buffer. Push is wait-free. Pop is lock-free.
    ##
    ## - N: The capacity of the queue.
    ## - C: The number of consumer threads.
    ## - T: The type of data the queue will hold.
    ##
    ## ```nim
    ## var queue = initSipmuc[64, 4, int]()
    ##
    ## # Single producer pushes directly
    ## discard queue.push(42)
    ##
    ## # Multiple consumers get handles
    ## let consumer = queue.getConsumer()
    ## let item = consumer.pop()
    ## ```

    reservedHead* {.align: 64.}: Atomic[int]
      ## The next slot to be claimed by a consumer. Consumers CAS this
      ## to reserve slots.
    committed*: array[N, Atomic[bool]]
      ## Per-slot commit flags. Set by producer after writing data.
      ## Checked/cleared by consumer. Enables lock-free pop.
    consumerThreadIds*: array[C, Atomic[int]]
      ## Array of consumer thread IDs by index.

  Consumer*[N, C: static int, T] = object
    ## A per-thread interface for popping items from a queue.
    ## Retrieved via a call to `Sipmuc.getConsumer()`.
    ##
    ## - N: The capacity of the queue.
    ## - C: The number of consumer threads.
    ## - T: The type of data the queue will hold.
    idx*: int
      ## The consumer's unique identifier (0 to C-1).
    queue*: ptr Sipmuc[N, C, T]
      ## A reference to the consumer's queue.


proc clear[N, C: static int, T](
  self: var Sipmuc[N, C, T]
) =
  ## Reset the queue to initial state.
  self.head.sequential(0)
  self.tail.sequential(0)
  self.reservedHead.sequential(0)

  for n in 0..<N:
    self.storage[n].reset()
    self.committed[n].store(false, moRelaxed)

  for c in 0..<C:
    self.consumerThreadIds[c].sequential(0)


proc initSipmuc*[N, C: static int, T](): Sipmuc[N, C, T] =
  ## Initialize a new Sipmuc queue.
  ##
  ## Returns a new Sipmuc queue instance.
  ##
  ## ```nim
  ## var queue = initSipmuc[64, 4, int]()
  ## ```
  result.clear()


proc consumerCount*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
): int
  {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C


proc push*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  ##
  ## This operation is wait-free for the single producer.
  let tail = self.tail.load(moAcquire)
  let tailIdx = index(tail, N)

  # Check if slot is still committed (not yet consumed) - queue is full
  if self.committed[tailIdx].load(moAcquire):
    return false

  # Write the item
  self.storage[tailIdx] = item

  # Mark slot as committed (data ready to read)
  self.committed[tailIdx].store(true, moRelease)

  # Advance tail
  let newTail = incOrReset(tail, 1, N)
  self.tail.store(newTail, moRelease)

  return true


proc push*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `NoSlice` is returned.
  ##
  ## This operation is wait-free for the single producer.
  if unlikely(items.len == 0):
    return NoSlice

  let tail = self.tail.load(moAcquire)

  # Count available slots by checking committed flags
  var avail = 0
  for i in 0..<min(items.len, N):
    let idx = index(incOrReset(tail, i, N), N)
    if self.committed[idx].load(moAcquire):
      break  # Hit a committed slot, stop
    inc avail

  if unlikely(avail == 0):
    return some(0..items.len - 1)

  var count: int
  if likely(avail >= items.len):
    result = NoSlice
    count = items.len
  else:
    result = some(avail..items.len - 1)
    count = avail

  let start = index(tail, N)
  var stop = incOrReset(tail, count - 1, N)
  stop = index(stop, N)

  if start > stop:
    # data may wrap
    let pivot = (N-1) - start
    self.storage[start..start+pivot] = items[0..pivot]
    if stop > 0:
      # data wraps
      self.storage[0..stop] = items[pivot+1..pivot+1+stop]
  else:
    # data does not wrap
    self.storage[start..stop] = items[0..stop-start]

  # Mark all written slots as committed
  for i in 0..<count:
    let idx = index(incOrReset(tail, i, N), N)
    self.committed[idx].store(true, moRelease)

  # Advance tail
  let newTail = incOrReset(tail, count, N)
  self.tail.store(newTail, moRelease)


proc getConsumer*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  idx: int = -1,
): Consumer[N, C, T]
  {.raises: [NoConsumersAvailableError].} =
  ## Assigns and returns a `Consumer` instance for the current thread.
  ##
  ## Optional explicit consumer index (0 to C-1). If not provided, assigns based on thread ID.
  ## Returns a Consumer instance for popping items.
  ## Raises NoConsumersAvailableError if all consumer slots are taken.
  ##
  ## ```nim
  ## var queue = initSipmuc[64, 4, int]()
  ## let consumer = queue.getConsumer()
  ## let item = consumer.pop()
  ## ```
  result.queue = addr(self)

  if idx >= 0:
    assert idx < C, "Consumer index " & $idx & " out of bounds (max " & $(C-1) & ")"
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
    "Increase your consumer count (C) or setMaxPoolSize(C).")


proc pop*[N, C: static int, T](
  self: Consumer[N, C, T],
): Option[T] =
  ## Pop a single item from the queue.
  ##
  ## Returns `some(T)` if an item was popped, `none(T)` if queue is empty.
  ##
  ## This operation is lock-free: consumers never block on each other.
  ##
  ## ```nim
  ## let consumer = queue.getConsumer()
  ## let item = consumer.pop()
  ## if item.isSome:
  ##   echo "Got: ", item.get
  ## ```

  var slot: int
  var newReservedHead: int

  # Claim a slot using CAS on reservedHead
  while true:
    slot = self.queue.reservedHead.load(moAcquire)
    let tail = self.queue.tail.load(moAcquire)

    if unlikely(empty(slot, tail, N)):
      return none(T)

    newReservedHead = incOrReset(slot, 1, N)

    if self.queue.reservedHead.compareExchangeWeak(
      slot,
      newReservedHead,
      moRelease,
      moAcquire,
    ):
      break

  let slotIdx = index(slot, N)

  # Check if slot is committed (data ready to read)
  # This should always be true for SPMC since producer sets committed before advancing tail
  if not self.queue.committed[slotIdx].load(moAcquire):
    return none(T)  # Should not happen in normal operation

  # Read the item from the claimed slot
  result = some(self.queue.storage[slotIdx])

  # Clear committed flag (slot can be reused by producer)
  # This is what signals to the producer that the slot is free
  self.queue.committed[slotIdx].store(false, moRelease)

  # Try to advance head (lock-free, may fail if other consumers are ahead)
  var expectedHead = slot
  discard self.queue.head.compareExchangeWeak(
    expectedHead,
    newReservedHead,
    moRelease,
    moAcquire,
  )


proc pop*[N, C: static int, T](
  self: Consumer[N, C, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ##
  ## Returns `some(seq[T])` with at least one item, or `none(seq[T])` if empty.
  ##
  ## ```nim
  ## let consumer = queue.getConsumer()
  ## let items = consumer.pop(10)
  ## if items.isSome:
  ##   for item in items.get:
  ##     echo item
  ## ```

  if unlikely(count <= 0):
    return none(seq[T])

  var actualCount: int
  var slot: int
  var newReservedHead: int

  # Claim slots using CAS on reservedHead
  while true:
    slot = self.queue.reservedHead.load(moAcquire)
    let tail = self.queue.tail.load(moAcquire)

    let avail = used(slot, tail, N)
    if likely(avail >= count):
      # Enough items to fulfill request
      actualCount = count
    elif avail <= 0:
      # Queue is empty, return nothing
      return none(seq[T])
    else:
      # Not enough items to fulfill request
      actualCount = min(avail, N)

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


proc pop*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
): Option[T] =
  ## Overload of `Sipsic.pop()` that raises `InvalidCallDefect`.
  ## Pops should happen via `Consumer.pop()`.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc pop*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  count: int,
): Option[seq[T]] =
  ## Overload of `Sipsic.pop()` that raises `InvalidCallDefect`.
  ## Pops should happen via `Consumer.pop()`.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


when defined(testing):
  from unittest import check

  proc reset*[N, C: static int, T](
    self: var Sipmuc[N, C, T]
  ) =
    ## Resets the queue to its default state.
    self.clear()

  proc checkState*[N, C: static int, T](
    self: var Sipmuc[N, C, T],
    head: int,
    reservedHead: int,
    tail: int,
  ) =
    ## Check internal queue state for testing.
    check(self.head.sequential == head)
    check(self.reservedHead.sequential == reservedHead)
    check(self.tail.sequential == tail)
