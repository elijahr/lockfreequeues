# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, multi-consumer bounded queue implemented as a ring buffer.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupmuc requires --threads:on option.".}

import atomics
import options

import ./ops
import ./mupsic


const NoConsumerIdx* = -1 ## The initial value of `Mupmuc.prevConsumerIdx`.


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

    prevConsumerIdx*: Atomic[int] ## The ID (index) of the most recent consumer
    consumerHeads*: array[C, Atomic[int]] ## Array of consumer heads
    consumerThreadIds*: array[C, Atomic[int]] ## \
      ## Array of consumer thread IDs by index

  Consumer*[N, P, C: static int, T] = object
    ## A per-thread interface for popping items from a queue.
    ## Retrieved via a call to `Mupmuc.getConsumer()`
    idx*: int ## The consumer's unique identifier.
    queue*: ptr Mupmuc[N, P, C, T] ## A reference to the consumer's queue.


proc clear[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T]
) =
  self.head.sequential(0)
  self.tail.sequential(0)

  for n in 0..<N:
    self.storage[n].reset()

  self.prevProducerIdx.sequential(NoConsumerIdx)
  for p in 0..<P:
    self.producerTails[p].sequential(0)
    self.producerThreadIds[p].sequential(0)

  self.prevConsumerIdx.sequential(NoConsumerIdx)
  for c in 0..<C:
    self.consumerHeads[c].sequential(0)
    self.consumerThreadIds[c].sequential(0)


proc initMupmuc*[N, P, C: static int, T](): Mupmuc[N, P, C, T] =
  ## Initialize a new Mupmuc queue.
  result.clear()


proc getConsumer*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  idx: int = NoConsumerIdx,
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

  var prevHead: int
  var newHead: int
  var prevConsumerIdx: int
  var isFirstConsumption: bool

  # spin until reservation is acquired
  while true:
    prevConsumerIdx = self.queue.prevConsumerIdx.acquire
    isFirstConsumption = prevConsumerIdx == NoConsumerIdx
    var tail = self.queue.tail.sequential
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


proc pop*[N, P, C: static int, T](
  self: Consumer[N, P, C, T],
  count: int,
): Option[seq[T]] =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## Otherwise `some(seq[T])` is returned containing at least one item.

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
    tail = self.queue.tail.sequential
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


proc pop*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
): bool  =
  ## Overload of `Sipsic.pop()` that simply raises `InvalidCallDefect`.
  ## Pops should happen via `Consumer.pop()`.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc pop*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
  count: int,
): Option[seq[T]] =
  ## Overload of `Sipsic.pop()` that simply raises `InvalidCallDefect`.
  ## Pops should happen via `Consumer.pop()`.
  raise newException(InvalidCallDefect, "Use Consumer.pop()")


proc consumerCount*[N, P, C: static int, T](
  self: var Mupmuc[N, P, C, T],
): int
  {.inline.} =
  ## Returns the queue's number of consumers (`C`).
  result = C


when defined(testing):
  import sugar
  from unittest import check

  proc reset*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T]
  ) =
    ## Resets the queue to its default state.
    self.clear()

  proc checkState*[N, P, C: static int, T](
    self: var Mupmuc[N, P, C, T],
    prevConsumerIdx: int,
    consumerHeads: seq[int],
  ) =
    check(self.prevConsumerIdx.sequential == prevConsumerIdx)
    let heads = collect(newSeq):
      for c in 0..<C:
        self.consumerHeads[c].sequential
    check(heads == consumerHeads)

