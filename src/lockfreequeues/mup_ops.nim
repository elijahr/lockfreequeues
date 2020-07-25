import options
import strformat

import ./atomic_dsl
import ./concepts
import ./ops
import ./producer


proc checkProducerId(
  producerId: int,
  producerCount: int,
) {.inline.} =
  # producerId must be be in the range [0, P)
  if producerId >= producerCount:
    raise newException(
      ValueError,
      fmt"producerId ({producerId}) must be in range 0..<{producerCount}")


template mupPushOne*(
  producerId: int,
  headLocation: untyped,
  tailLocation: untyped,
  prevProducerIdLocation: untyped,
  producerLocations: untyped,
  producerCount: int,
  storage: untyped,
  capacity: int,
  item: untyped,
) =
  checkProducerId(producerId, producerCount)

  var prevPid = prevProducerIdLocation.relaxed
  let pid = typeof(prevPid)(producerId)
  var producer = producerLocations[pid].relaxed
  doAssert producer.state == Synchronized

  # Mark this producer reserved
  producer.state = Reserved
  producerLocations[pid].release(producer)

  var head = headLocation.acquire.int
  var tail = producerLocations[prevPid].relaxed.tail.int

  # spin until reservation is acquired
  while true:
    if unlikely(full(head, tail, capacity)):
      # Queue is full, reset state to Synchronized and return
      producer.state = Synchronized
      producerLocations[pid].release(producer)
      return false

    if prevProducerIdLocation.compareExchangeWeakReleaseRelaxed(
      prevPid,
      pid,
    ):
      break
    else:
      head = headLocation.acquire.int
      tail = producerLocations[prevPid].relaxed.tail.int

  result = true

  let writeIndex = index(tail, capacity)
  storage[writeIndex] = item

  # Mark reservation pending for synchronization
  producer.state = Pending
  producer.tail = typeof(producer.tail)(incOrReset(tail, 1, capacity))
  producer.prevPid = prevPid
  producerLocations[pid].release(producer)

  # Spin until preceding reservation is synchronized, unless this producer
  # was the previous one.
  if pid != prevPid:
    while true:
      if producerLocations[prevPid].relaxed.state == Synchronized:
        break

  # Update tail
  tailLocation.release(producer.tail)

  # Mark synchronized
  producer.state = Synchronized
  producerLocations[pid].release(producer)


proc mupStaticPushOne*(
  self: var MupStaticQueue,
  producerId: int,
  item: self.ItemType,
): bool =
  mupPushOne(
    producerId,
    self.head,
    self.tail,
    self.prevPid,
    self.producers,
    self.producerCount,
    self.storage,
    self.capacity,
    item,
  )


template mupPushMany*(
  producerId: int,
  headLocation: untyped,
  tailLocation: untyped,
  prevProducerIdLocation: untyped,
  producerLocations: untyped,
  producerCount: int,
  storage: untyped,
  capacity: int,
  items: untyped,
) =
  checkProducerId(producerId, producerCount)

  if unlikely(items.len == 0):
    # items is empty, return nothing
    return

  var prevPid = prevProducerIdLocation.relaxed
  let pid = typeof(prevPid)(producerId)
  var producer = producerLocations[pid].relaxed
  doAssert producer.state == Synchronized

  # Mark this producer reserved
  producer.state = Reserved
  producerLocations[pid].release(producer)

  var head = headLocation.acquire.int
  var tail = producerLocations[prevPid].relaxed.tail.int
  var count: int
  var avail: int

  # spin until reservation is acquired
  while true:
    avail = available(head, tail, capacity)
    if likely(avail >= items.len):
      # enough room to push all items
      count = items.len
    else:
      if avail == 0:
        # Queue is full, reset state to Synchronized and return
        producer.state = Synchronized
        producerLocations[pid].release(producer)
        result = some(items[0..^1])
      # not enough room to push all items
      count = avail

    if prevProducerIdLocation.compareExchangeWeakReleaseRelaxed(
      prevPid,
      typeof(prevPid)(pid),
    ):
      break
    else:
      head = headLocation.acquire.int
      tail = producerLocations[prevPid].relaxed.tail.int

  if count < items.len:
    # give back remainder
    result = some(items[avail..^1])

  let writeStartIndex = index(tail, capacity)
  var writeEndIndex = index((tail + count) - 1, capacity)

  if writeStartIndex > writeEndIndex:
    # data may wrap
    let itemsPivotIndex = (capacity-1) - writeStartIndex
    for i in 0..itemsPivotIndex:
      storage[writeStartIndex+i] = items[i]
    if writeEndIndex > 0:
      # data wraps
      for i in 0..writeEndIndex:
        storage[i] = items[itemsPivotIndex+1+i]
  else:
    # data does not wrap
    for i in 0..writeEndIndex-writeStartIndex:
      storage[writeStartIndex+i] = items[i]

  # Mark reservation pending for synchronization
  producer.state = Pending
  producer.tail = typeof(producer.tail)(incOrReset(tail, count, capacity))
  producer.prevPid = prevPid
  producerLocations[pid].release(producer)

  # Spin until preceding reservation is synchronized, unless this producer
  # was the previous one.
  if pid != prevPid:
    while true:
      if producerLocations[prevPid].relaxed.state == Synchronized:
        break

  # Update tail
  tailLocation.release(producer.tail)

  # Mark synchronized
  producer.state = Synchronized
  producerLocations[pid].release(producer)


# proc mupSharedPushMany*(
#   self: ref SharedQueue,
#   items: openArray[self[].ItemType],
# ): Option[seq[self[].ItemType]] =
#   ## Append multiple items to the queue.
#   ## If the queue is already full or is filled by this call, `some(unpushed)`
#   ## is returned, where `unpushed` is a `seq[T]` containing the items which
#   ## cannot be appended.
#   ## If all items are appended, `none(seq[T])` is returned.
#   sipPushMany(
#     self[].head,
#     self[].tail,
#     self[].storage[],
#     self[].capacity,
#     items,
#   )


proc mupStaticPushMany*(
  self: var StaticQueue,
  producerId: int,
  items: openArray[self.ItemType],
): Option[seq[self.ItemType]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  mupPushMany(
    producerId,
    self.head,
    self.tail,
    self.prevPid,
    self.producers,
    self.producerCount,
    self.storage,
    self.capacity,
    items,
  )

