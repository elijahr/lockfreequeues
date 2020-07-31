# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## A multi-producer, single-consumer queue, implemented as a ring buffer,
## suitable for when the capacity and producer count are known at
## compile-time.

import atomics
import options
import strformat

import ./ops
import ./producer
import ./sipsic


type
  Mupsic*[N, P: static int, T] = object of Sipsic[N, T]
    ## A multi-producer, single-consumer queue, implemented as a ring buffer,
    ## suitable for when the capacity and producer count are known at
    ## compile-time.

    prevPid*: Atomic[int] ## \
      ## The ID of the most recent Producer

    producers*: array[P, Atomic[Producer]] ## \
      ## Producers packed into int64, for atomic reading/writing


proc checkPid[N, P: static int, T](
  self: var Mupsic[N, P, T],
  pid: int,
) {.inline.} =
  # pid must be be in the range [0, P)
  if pid >= P:
    raise newException(
      ValueError,
      fmt"pid ({pid}) must be in range 0..<{P}")


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  pid: int,
  item: T,
): bool =
  self.checkPid(pid)

  var prevPid = self.prevPid.relaxed
  var producer = self.producers[pid].relaxed
  assert producer.state == Synchronized

  # Mark this producer reserved
  producer.state = Reserved
  self.producers[pid].release(producer)

  var head = self.head.acquire.int
  var tail = self.producers[prevPid].relaxed.tail.int

  # spin until reservation is acquired
  while true:
    if unlikely(full(head, tail, N)):
      # Queue is full, reset state to Synchronized and return
      producer.state = Synchronized
      self.producers[pid].release(producer)
      return false
    else:
      # Propagate previous tail to this producer so it is visible to other
      # producers when the below compareExchange() is successful.
      producer.tail = tail
      self.producers[pid].release(producer)

    if self.prevPid.compareExchangeWeakReleaseRelaxed(
      prevPid,
      pid,
    ):
      break
    else:
      cpuRelax()
      head = self.head.acquire.int
      tail = self.producers[prevPid].relaxed.tail.int

  result = true

  let writeIndex = index(tail, N)
  self.storage[writeIndex] = item

  # Mark reservation pending for synchronization
  producer.state = Pending
  producer.tail = incOrReset(tail, 1, N)
  producer.prevPid = prevPid
  self.producers[pid].release(producer)

  # Spin until preceding reservation is synchronized, unless this producer
  # was the previous one.

  # TODO: Or not? what else can be done? Perhaps a queue for tails?
  # Or storing head on Producer as well?
  if pid != prevPid:
    while true:
      if self.producers[prevPid].relaxed.state == Synchronized:
        break
      else:
        cpuRelax()

  # Update tail
  self.tail.release(producer.tail)

  # Mark synchronized
  producer.state = Synchronized
  self.producers[pid].release(producer)


proc push*[N, P: static int, T](
  self: var Mupsic[N, P, T],
  pid: int,
  items: openArray[T],
): Option[seq[T]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  self.checkPid(pid)

  if unlikely(items.len == 0):
    # items is empty, return nothing
    return

  var prevPid = self.prevPid.relaxed
  var producer = self.producers[pid].relaxed
  assert producer.state == Synchronized

  # Mark this producer reserved
  producer.state = Reserved
  self.producers[pid].release(producer)

  var head = self.head.acquire.int
  var tail = self.producers[prevPid].relaxed.tail.int
  var count: int
  var avail: int

  # spin until reservation is acquired
  while true:
    avail = available(head, tail, N)
    if likely(avail >= items.len):
      # enough room to push all items
      count = items.len
    else:
      if avail == 0:
        # Queue is full, reset state to Synchronized and return
        producer.state = Synchronized
        self.producers[pid].release(producer)
        return some(items[0..^1])
      else:
        # not enough room to push all items
        count = avail

    # Propagate previous tail to this producer so it is visible to other
    # producers when the below compareExchange() is successful.
    producer.tail = tail
    self.producers[pid].release(producer)

    if self.prevPid.compareExchangeWeakReleaseRelaxed(
      prevPid,
      pid,
    ):
      break
    else:
      cpuRelax()
      head = self.head.acquire.int
      tail = self.producers[prevPid].relaxed.tail.int

  if count < items.len:
    # give back remainder
    result = some(items[avail..^1])

  let writeStartIndex = index(tail, N)
  var writeEndIndex = index((tail + count) - 1, N)

  if writeStartIndex > writeEndIndex:
    # data may wrap
    let itemsPivotIndex = (N-1) - writeStartIndex
    for i in 0..itemsPivotIndex:
      self.storage[writeStartIndex+i] = items[i]
    if writeEndIndex > 0:
      # data wraps
      for i in 0..writeEndIndex:
        self.storage[i] = items[itemsPivotIndex+1+i]
  else:
    # data does not wrap
    for i in 0..writeEndIndex-writeStartIndex:
      self.storage[writeStartIndex+i] = items[i]

  # Mark reservation pending for synchronization
  producer.state = Pending
  producer.tail = incOrReset(tail, count, N)
  producer.prevPid = prevPid
  self.producers[pid].release(producer)

  # Spin until preceding reservation is synchronized, unless this producer
  # was the previous one.
  if pid != prevPid:
    while true:
      if self.producers[prevPid].relaxed.state == Synchronized:
        break
      else:
        cpuRelax()

  # Update tail
  self.tail.release(producer.tail)

  # Mark synchronized
  producer.state = Synchronized
  self.producers[pid].release(producer)

