# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, single-consumer bounded queue implemented as a ring buffer.

when not compileOption("threads") or defined(nimdoc):
  {.error: "lockfreequeues/mupsic requires --threads:on option.".}

import atomics
import options

import ./atomic_dsl
import ./exceptions
import ./ops
import ./sipsic

const NoProducerIdx* = -1 ## The initial value of `Mupsic.prevProducerIdx`.

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
    producerReleases*: array[P, Atomic[bool]] ## \
      ## Array indicating whether producers have been released by release()

  # MupsicRef*[N, P: static int, T] = ref Mupsic[N, P, T]

  Producer*[N, P: static int, T] = object
    ## A per-thread interface for pushing items to a queue.
    ## Retrieved via a call to `Mupsic.getProducer()`
    idx*: int ## The producer's unique identifier.
    queuePtr*: ptr Mupsic[N, P, T] ## A pointer to the producer's queue.


proc clear*[N, P: static int, T](
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
    self.producerReleases[p].sequential(true)


proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] =
  ## Initialize a new Mupsic queue.
  result.head.sequential(0)
  result.tail.sequential(0)

  for n in 0..<N:
    result.storage[n].reset()

  result.prevProducerIdx.sequential(NoProducerIdx)
  for p in 0..<P:
    result.producerTails[p].sequential(0)
    result.producerThreadIds[p].sequential(0)
    result.producerReleases[p].sequential(true)


proc getProducer*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  idx: int = NoProducerIdx,
): Producer[N, P, T]
  {.raises: [NoProducersAvailableError].} =
  ## Assigns and returns a `Producer` instance for the current thread.
  result.queuePtr = addr self

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
    if self.producerThreadIds[idx].compareExchange(
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


proc release*[N, P: static int, T](producer: var Producer[N, P, T]) =
  producer.queuePtr.producerReleases[producer.idx].release(true)


proc released*[N, P: static int, T](
  producer: var Producer[N, P, T]
): bool {.noSideEffect.} =
  return producer.queuePtr.producerReleases[producer.idx].relaxed


proc push*[N, P: static int, T](
  self: var Producer[N, P, T],
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
    prevProducerIdx = self.queuePtr.prevProducerIdx.acquire
    isFirstProduction = prevProducerIdx == NoProducerIdx
    var head = self.queuePtr.head.sequential
    prevTail =
      if unlikely(isFirstProduction):
        0
      else:
        self.queuePtr.producerTails[prevProducerIdx].acquire

    if unlikely(full(head, prevTail, N)):
      return false

    newTail = incOrReset(prevTail, 1, N)
    # validateHeadAndTail(head, newTail, N)
    self.queuePtr.producerTails[self.idx].release(newTail)

    if self.queuePtr.prevProducerIdx.compareExchangeWeak(
      prevProducerIdx,
      self.idx,
      moRelease,
      moAcquire,
    ):
      break

  result = true

  self.queuePtr.storage[index(prevTail, N)] = item

  if unlikely(isFirstProduction):
    self.queuePtr.tail.release(newTail)
  else:
    # Wait for prev producer to update tail, then update tail
    while true:
      var expectedTail = prevTail
      if self.queuePtr.tail.compareExchangeWeak(
        expectedTail,
        newTail,
        moRelease,
        moAcquire,
      ):
        break


proc push*[N, P: static int, T](
  self: var Producer[N, P, T],
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
    prevProducerIdx = self.queuePtr.prevProducerIdx.acquire
    isFirstProduction = prevProducerIdx == NoProducerIdx
    var head = self.queuePtr.head.sequential
    prevTail =
      if isFirstProduction:
        0
      else:
        self.queuePtr.producerTails[prevProducerIdx].acquire

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
    # validateHeadAndTail(head, newTail, N)
    self.queuePtr.producerTails[self.idx].release(newTail)

    if self.queuePtr.prevProducerIdx.compareExchangeWeak(
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
    self.queuePtr.storage[start..start+pivot] = items[0..pivot]
    if stop > 0:
      # data wraps
      self.queuePtr.storage[0..stop] = items[pivot+1..pivot+1+stop]
  else:
    # data does not wrap
    self.queuePtr.storage[start..stop] = items[0..stop-start]

  if unlikely(isFirstProduction):
    self.queuePtr.tail.release(newTail)
  else:
    # Wait for prev producer to update tail, then update tail
    while true:
      var expectedTail = prevTail
      if self.queuePtr.tail.compareExchangeWeak(
        expectedTail,
        newTail,
        moRelease,
        moAcquire,
      ):
        break


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  item: T,
): bool =
  ## Overload of `Sipsic.push()` that simply raises `InvalidCallDefect`.
  ## Pushes should happen via `Producer.push()`.
  raise newException(InvalidCallDefect, "Use Producer.push()")


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  items: openArray[T],
): Option[HSlice[int, int]] =
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


proc `=copy`*[N, P: static int, T](a: var Mupsic[N, P, T], b: Mupsic[N, P, T]) {.error.}


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
    check(self.prevProducerIdx.acquire == prevProducerIdx)
    let tails = collect(newSeq):
      for p in 0..<P:
        self.producerTails[p].acquire
    check(tails == producerTails)
