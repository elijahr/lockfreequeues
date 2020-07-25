import options

import ./concepts
import ./atomic_dsl
import ./ops


template sicPopOne*(
  headLocation: untyped,
  tailLocation: untyped,
  storage: untyped,
  capacity: int,
) =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  let tail = tailLocation.acquire
  let head = headLocation.relaxed

  if unlikely(empty(head.int, tail.int)):
    return

  let headIndex = index(head.int, capacity.int)

  result = some(storage[headIndex])

  let newHead = typeof(head)(incOrReset(head.int, 1, capacity.int))

  headLocation.release(newHead)


proc sicSharedPopOne*[T](
  self: ref SharedQueue[T],
): Option[T] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  sicPopOne(
    self[].head,
    self[].tail,
    self[].storage[],
    self[].capacity,
  )


proc sicStaticPopOne*(
  self: var StaticQueue,
): Option[self.ItemType] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  sicPopOne(
    self.head,
    self.tail,
    self.storage,
    self.capacity,
  )


template sicPopMany*(
  headLocation: untyped,
  tailLocation: untyped,
  storage: untyped,
  capacity: untyped,
  count: untyped,
  itemType: typedesc,
) =
  ## Pop `count` items from the queue.
  ## If the queue is empty, `none(seq[T])` is returned.
  ## If > 1 items are popped, `some(seq[T])` is returned.
  let tail = tailLocation.acquire
  let head = headLocation.relaxed

  if unlikely(empty(head.int, tail.int)):
    return

  let size = used(head.int, tail.int, capacity.int)

  let itemCount =
    if likely(size >= count):
      # enough data to pop count
      count
    else:
      # not enough data to pop count
      size

  var res = newSeq[itemType](itemCount)
  let headIndex = index(head.int, capacity.int)
  let newHead = typeof(head)(incOrReset(head.int, itemCount.int, capacity.int))
  let newHeadIndex = index(newHead.int, capacity.int)

  if headIndex < newHeadIndex:
    # request does not wrap
    for i in 0..<itemCount:
      res[i] = storage[headIndex+i]
  else:
    # request may wrap
    var i = 0
    for j in headIndex..<capacity:
      res[i] = storage[j]
      inc i
    if newHeadIndex > 0:
      # request wraps
      for j in 0..<newHeadIndex:
        res[i] = storage[j]
        inc i

  result = some(res)

  headLocation.release(newHead)


proc sicSharedPopMany*(
  self: ref SharedQueue,
  count: int,
): Option[seq[self.ItemType]] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  sicPopMany(
    self[].head,
    self[].tail,
    self[].storage[],
    self[].capacity,
    count,
    self.ItemType,
  )


proc sicStaticPopMany*(
  self: var StaticQueue,
  count: int,
): Option[seq[self.ItemType]] =
  ## Pop a single item from the queue.
  ## If the queue is empty, `none(T)` is returned.
  ## If an item is popped, `some(T)` is returned.
  sicPopMany(
    self.head,
    self.tail,
    self.storage,
    self.capacity,
    count,
    self.ItemType,
  )
