import options

import ./concepts
import ./ops


template sipPushOne*(
  headLocation: untyped,
  tailLocation: untyped,
  storage: untyped,
  capacity: int,
  item: untyped,
) =
  let tail = tailLocation.relaxed
  let head = headLocation.acquire

  if unlikely(full(head, tail, capacity)):
    # queue is full, return false
    return false

  let writeIndex = index(tail, capacity)

  storage[writeIndex] = item

  result = true

  tailLocation.release(incOrReset(tail, 1, capacity))


proc sipSharedPushOne*(
  self: ref SharedQueue,
  item: self.ItemType,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  sipPushOne(
    self[].head,
    self[].tail,
    self[].storage[],
    self[].capacity,
    item,
  )


proc sipStaticPushOne*(
  self: var StaticQueue,
  item: self.ItemType,
): bool =
  ## Append a single item to the queue.
  ## If the queue is full, `false` is returned.
  ## If `item` is appended, `true` is returned.
  sipPushOne(
    self.head,
    self.tail,
    self.storage,
    self.capacity,
    item,
  )


template sipPushMany*(
  headLocation: untyped,
  tailLocation: untyped,
  storage: untyped,
  capacity: int,
  items: untyped,
) =
  if unlikely(items.len == 0):
    # items is empty, return nothing
    return

  let tail = tailLocation.relaxed
  let head = headLocation.acquire

  if unlikely(full(head, tail, capacity)):
    # queue is full, return everything
    return some(items[0..^1])

  let avail = available(head, tail, capacity)
  var count: int

  if likely(avail >= items.len):
    # enough room to push all items, return nothing
    count = items.len
  else:
    # not enough room to push all items, return remainder
    result = some(items[avail..^1])
    count = avail

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

  tailLocation.release(incOrReset(tail, count, capacity))


proc sipSharedPushMany*(
  self: ref SharedQueue,
  items: openArray[self[].ItemType],
): Option[seq[self[].ItemType]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  sipPushMany(
    self[].head,
    self[].tail,
    self[].storage[],
    self[].capacity,
    items,
  )


proc sipStaticPushMany*(
  self: var StaticQueue,
  items: openArray[self.ItemType],
): Option[seq[self.ItemType]] =
  ## Append multiple items to the queue.
  ## If the queue is already full or is filled by this call, `some(unpushed)`
  ## is returned, where `unpushed` is a `seq[T]` containing the items which
  ## cannot be appended.
  ## If all items are appended, `none(seq[T])` is returned.
  sipPushMany(
    self.head,
    self.tail,
    self.storage,
    self.capacity,
    items,
  )
