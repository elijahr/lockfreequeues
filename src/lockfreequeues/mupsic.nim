# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, single-consumer bounded queue implemented as a ring buffer.

when not compileOption("threads"):
  {.error: "lockfreequeues/mupsic requires --threads:on option.".}

import atomics
import options

import ./ops
import ./sipsic


const NoProducerIdx* = -1 ## The initial value of `Mupsic.prevProducerIdx`.


type NoProducersAvailableDefect* = object of Defect ## \
  ## Raised by `getProducer()` if all producers have been assigned to other
  ## threads.

type InvalidCallDefect* = object of Defect ## \
  ## Raised by `Mupsic.push()`, `Mupmuc.push()`, and `Mupmuc.pop()` because
  ## those should happen via `Producer.push()` or `Consumer.pop()`.

type
  Mupsic*[N, P: static int, T] = object of Sipsic[N, T]
    ## A multi-producer, single-consumer bounded queue implemented as a ring
    ## buffer. Popping is wait-free.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `T` is the type of data the queue will hold.

    prevProducerIdx*: Atomic[int] ## The ID (index) of the most recent producer
    producerTails*: array[P, Atomic[int]] ## Array of producer tails
    producerThreadIds*: array[P, Atomic[int]] ## \
      ## Array of producer thread IDs by index

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

  for n in 0..<N:
    self.storage[n].reset()

  self.prevProducerIdx.sequential(NoProducerIdx)
  for p in 0..<P:
    self.producerTails[p].sequential(0)
    self.producerThreadIds[p].sequential(0)


proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] =
  ## Initialize a new Mupsic queue.
  result.clear()


proc getProducer*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  idx: int = NoProducerIdx,
): Producer[N, P, T]
  {.raises: [NoProducersAvailableDefect].} =
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
    NoProducersAvailableDefect,
    "All producers have been assigned. " &
    "Increase your producer count (P) or setMaxPoolSize(P).")


proc push*[N, P: static int, T](
  self: Producer[N, P, T],
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.

  var prevTail: int
  var newTail: int
  var prevProducerIdx: int
  var isFirstProduction: bool

  # spin until reservation is acquired
  while true:
    prevProducerIdx = self.queue.prevProducerIdx.acquire
    isFirstProduction = prevProducerIdx == NoProducerIdx
    var head = self.queue.head.sequential
    prevTail =
      if isFirstProduction:
        0
      else:
        self.queue.producerTails[prevProducerIdx].acquire

    if unlikely(full(head, prevTail, N)):
      return false

    newTail = incOrReset(prevTail, 1, N)
    # validateHeadAndTail(head, newTail, N)
    self.queue.producerTails[self.idx].release(newTail)

    if self.queue.prevProducerIdx.compareExchangeWeak(
      prevProducerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  result = true

  self.queue.storage[index(prevTail, N)] = item

  # Wait for prev producer to update tail, then update tail
  if not isFirstProduction:
    while true:
      var expectedTail = prevTail
      if self.queue.tail.compareExchangeWeak(
        expectedTail,
        newTail,
        moRelease,
        moAcquire,
      ):
        break
  else:
    self.queue.tail.release(newTail)


proc push*[N, P: static int, T](
  self: Producer[N, P, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is an `HSlice` corresponding to the
  ## chunk of items which could not be pushed.
  ## If all items are appended, `none(HSlice[int, int])` is returned.
  if unlikely(items.len == 0):
    # items is empty, nothing unpushed
    return NoSlice

  var count: int
  var avail: int
  var prevTail: int
  var newTail: int
  var prevProducerIdx: int
  var isFirstProduction: bool

  # spin until reservation is acquired
  while true:
    prevProducerIdx = self.queue.prevProducerIdx.acquire
    isFirstProduction = prevProducerIdx == NoProducerIdx
    var head = self.queue.head.sequential
    prevTail =
      if isFirstProduction:
        0
      else:
        self.queue.producerTails[prevProducerIdx].acquire

    avail = available(head, prevTail, N)
    if likely(avail >= items.len):
      # enough room to push all items
      count = items.len
    else:
      if avail <= 0:
        # Queue is full, return
        return some(0..items.len - 1)
      else:
        # not enough room to push all items
        count = avail

    newTail = incOrReset(prevTail, count, N)
    #  validateHeadAndTail(head, newTail, N)
    self.queue.producerTails[self.idx].release(newTail)

    if self.queue.prevProducerIdx.compareExchangeWeak(
      prevProducerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  if count < items.len:
    # give back remainder
    result = some(avail..items.len - 1)
  else:
    result = NoSlice

  let start = index(prevTail, N)
  var stop = incOrReset(prevTail, count - 1, N)
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

  # Wait for prev producer to update tail, then update tail
  if not isFirstProduction:
    while true:
      var expectedTail = prevTail
      if self.queue.tail.compareExchangeWeak(
        expectedTail,
        newTail,
        moRelease,
        moAcquire,
      ):
        break

  elif isFirstProduction:
    self.queue.tail.release(newTail)


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  item: T,
): bool
  {.raises: [InvalidCallDefect].} =
  ## Overload of `Sipsic.push()` that simply raises `InvalidCallDefect`.
  ## Pushes should happen via `Producer.push()`.
  raise newException(InvalidCallDefect, "Use Producer.push()")


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  items: openArray[T],
): Option[HSlice[int, int]]
  {.raises: [InvalidCallDefect].} =
  ## Overload of `Sipsic.push()` that simply raises `InvalidCallDefect`.
  ## Pushes should happen via `Producer.push()`.
  raise newException(InvalidCallDefect, "Use Producer.push()")


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
  import sugar
  from unittest import check

  proc reset*[N, P: static int, T](
    self: var Mupsic[N, P, T]
  ) =
    ## Resets the queue to its default state.
    ## Probably only useful in single-threaded unit tests.
    self.clear()

  proc checkState*[N, P: static int, T](
    self: var Mupsic[N, P, T],
    prevProducerIdx: int,
    producerTails: seq[int],
  ) =
    let tails = collect(newSeq):
      for p in 0..<P:
        self.producerTails[p].acquire
    check(self.prevProducerIdx.acquire == prevProducerIdx)
    check(tails == producerTails)
