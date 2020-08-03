# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A bounded, multi-producer, single-consumer queue implemented as a ring
## buffer.

import atomics
import options
import sequtils
import sugar

import ./ops
import ./sipsic


const FirstProduction = -1
const NoSlice = none(HSlice[int, int])


type
  Mupsic*[N, P: static int, T] = object of Sipsic[N, T]
    ## A bounded, multi-producer, single-consumer queue implemented as a ring
    ## buffer.
    ##
    ## * `N` is the capacity of the queue.
    ## * `P` is the number of producer threads.
    ## * `T` is the type of data the queue will hold.

    prevPid*: Atomic[int] ## The ID of the most recent Producer

    producers*: array[P, Atomic[int]] ## Array of producer tails


proc initMupsic*[N, P: static int, T](): Mupsic[N, P, T] =
  result.prevPid.release(FirstProduction)


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  pid: int,
  item: T,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.

  var prevTail: int
  var newTail: int
  var prevPid: int
  var isFirstProduction: bool

  # spin until reservation is acquired
  while true:
    prevPid = self.prevPid.acquire
    isFirstProduction = prevPid == FirstProduction
    var head = self.head.acquire
    prevTail =
      if isFirstProduction:
        0
      else:
        self.producers[prevPid].acquire

    if unlikely(full(head, prevTail, N)):
      return false

    newTail = incOrReset(prevTail, 1, N)
    self.producers[pid].release(newTail)

    if self.prevPid.compareExchangeWeak(
      prevPid,
      pid,
      moAcquire,
      moRelaxed,
    ):
      break

    cpuRelax()

  result = true

  self.storage[index(prevTail, N)] = item

  # Wait for prev producer to update tail, then update tail
  if not isFirstProduction:
    while true:
      var expectedTail = prevTail
      if self.tail.compareExchangeWeak(
        expectedTail,
        newTail,
        moAcquire,
        moRelaxed,
      ):
        break
      cpuRelax()
  elif isFirstProduction:
    self.tail.release(newTail)


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  pid: int,
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
  var prevPid: int
  var isFirstProduction: bool

  # spin until reservation is acquired
  while true:
    prevPid = self.prevPid.acquire
    isFirstProduction = prevPid == FirstProduction
    var head = self.head.acquire
    prevTail =
      if isFirstProduction:
        0
      else:
        self.producers[prevPid].acquire

    avail = available(head, prevTail, N)
    if likely(avail >= items.len):
      # enough room to push all items
      count = items.len
    else:
      if avail == 0:
        # Queue is full, return
        return some(0..items.len - 1)
      else:
        # not enough room to push all items
        count = avail

    newTail = incOrReset(prevTail, count, N)
    self.producers[pid].release(newTail)

    if self.prevPid.compareExchangeWeak(
      prevPid,
      pid,
      moAcquire,
      moRelaxed,
    ):
      break

    cpuRelax()

  if count < items.len:
    # give back remainder
    result = some(avail..items.len - 1)
  else:
    result = NoSlice

  let start = index(prevTail, N)
  var stop = index((prevTail + count) - 1, N)

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

  # Wait for prev producer to update tail, then update tail
  if not isFirstProduction:
    while true:
      var expectedTail = prevTail
      if self.tail.compareExchangeWeak(
        expectedTail,
        newTail,
        moAcquire,
        moRelaxed,
      ):
        break
      cpuRelax()
  elif isFirstProduction:
    self.tail.release(newTail)


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


proc reset*[N, P: static int, T](
  self: var Mupsic[N, P, T]
) {.inline.} =
  ## Resets the queue to its default state.
  ## Proably only useful in single-threaded unit tests.
  doAssert(defined(testing))
  self.head.release(0)
  self.tail.release(0)
  self.prevPid.release(FirstProduction)
  self.storage[0..<N] = repeat(0, N)
  for p in 0..<P:
    self.producers[p].release(0)


proc state*[N, P: static int, T](
  self: var Mupsic[N, P, T],
): tuple[
    head: int,
    tail: int,
    prevPid: int,
    storage: seq[T],
    producers: seq[int],
  ] =
  ## Retrieve current state of the queue.
  ## Proably only useful in single-threaded unit tests,
  ## as data may be torn.
  doAssert(defined(testing))
  let producers = collect(newSeq):
    for p in 0..<P:
      self.producers[p].acquire
  return (
    head: self.head.acquire,
    tail: self.tail.acquire,
    prevPid: self.prevPid.acquire,
    storage: self.storage[0..^1],
    producers: producers
  )
