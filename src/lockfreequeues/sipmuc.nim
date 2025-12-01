# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A single-producer, multi-consumer bounded queue implemented as a ring buffer.
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


const NoConsumerIdx* = -1
  ## The initial value of `Sipmuc.prevConsumerIdx`.
  ## Indicates no consumer has popped yet.


type NoConsumersAvailableError* = object of CatchableError
  ## Raised by `getConsumer()` if all consumers have been assigned to other
  ## threads.


type
  Sipmuc*[N, C: static int, T] = object of Sipsic[N, T]
    ## A single-producer, multi-consumer bounded queue implemented as a ring
    ## buffer. Pushing is wait-free. Popping is lock-free.
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

    prevConsumerIdx*: Atomic[int]
      ## The ID (index) of the most recent consumer.
    consumerHeads*: array[C, Atomic[int]]
      ## Array of consumer heads, one per consumer thread.
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

  for n in 0..<N:
    self.storage[n].reset()

  self.prevConsumerIdx.sequential(NoConsumerIdx)
  for c in 0..<C:
    self.consumerHeads[c].sequential(0)
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


proc getConsumer*[N, C: static int, T](
  self: var Sipmuc[N, C, T],
  idx: int = NoConsumerIdx,
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
  ## ```nim
  ## let consumer = queue.getConsumer()
  ## let item = consumer.pop()
  ## if item.isSome:
  ##   echo "Got: ", item.get
  ## ```

  var prevHead: int
  var newHead: int
  var prevConsumerIdx: int
  var isFirstConsumption: bool

  # spin until reservation is acquired
  while true:
    prevConsumerIdx = self.queue.prevConsumerIdx.acquire
    isFirstConsumption = prevConsumerIdx == NoConsumerIdx
    var tail = self.queue.tail.acquire
    prevHead =
      if isFirstConsumption:
        0
      else:
        self.queue.consumerHeads[prevConsumerIdx].acquire

    if unlikely(empty(prevHead, tail, N)):
      return none(T)

    newHead = incOrReset(prevHead, 1, N)
    self.queue.consumerHeads[self.idx].release(newHead)

    if self.queue.prevConsumerIdx.compareExchangeWeak(
      prevConsumerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  result = some(self.queue.storage[index(prevHead, N)])

  # Wait for prev consumer to update head, then update head
  if not isFirstConsumption:
    while true:
      var expectedHead = prevHead
      if self.queue.head.compareExchangeWeak(
        expectedHead,
        newHead,
        moRelease,
        moAcquire,
      ):
        break
  else:
    self.queue.head.release(newHead)


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
  var used: int
  var prevHead: int
  var newHead: int
  var prevConsumerIdx: int
  var isFirstConsumption: bool
  var tail: int

  # spin until reservation is acquired
  while true:
    prevConsumerIdx = self.queue.prevConsumerIdx.acquire
    isFirstConsumption = prevConsumerIdx == NoConsumerIdx
    tail = self.queue.tail.acquire
    prevHead =
      if isFirstConsumption:
        0
      else:
        self.queue.consumerHeads[prevConsumerIdx].acquire

    used = used(prevHead, tail, N)
    if likely(used >= count):
      # Enough items to fulfill request
      actualCount = count
    elif used <= 0:
      # Queue is empty, return nothing
      return none(seq[T])
    else:
      # Not enough items to fulfill request
      actualCount = min(used, N)

    newHead = incOrReset(prevHead, actualCount, N)
    self.queue.consumerHeads[self.idx].release(newHead)

    if self.queue.prevConsumerIdx.compareExchangeWeak(
      prevConsumerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  let start = index(prevHead, N)
  var stop = incOrReset(prevHead, actualCount - 1, N)
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

  # Wait for prev consumer to update head, then update head
  if not isFirstConsumption:
    while true:
      var expectedHead = prevHead
      if self.queue.head.compareExchangeWeak(
        expectedHead,
        newHead,
        moRelease,
        moAcquire,
      ):
        break

  elif isFirstConsumption:
    self.queue.head.release(newHead)


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
  import sugar
  from unittest import check

  proc reset*[N, C: static int, T](
    self: var Sipmuc[N, C, T]
  ) =
    ## Resets the queue to its default state.
    self.clear()

  proc checkState*[N, C: static int, T](
    self: var Sipmuc[N, C, T],
    prevConsumerIdx: int,
    consumerHeads: seq[int],
  ) =
    check(self.prevConsumerIdx.sequential == prevConsumerIdx)
    let heads = collect(newSeq):
      for c in 0..<C:
        self.consumerHeads[c].sequential
    check(heads == consumerHeads)
