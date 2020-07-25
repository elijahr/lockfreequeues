# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Operations used internally by
## `SipsicQueueInterface <queueinterface.html#SipsicQueueInterface>`_.


template assertHeadOrTail(
  value: int,
  capacity: int,
) =
  ## Assert that the given `value` is in the range `0..<2*capacity`.
  assert(value in 0..<(2 * capacity))


proc index*(
  value: int,
  capacity: int,
): int
  {.inline.} =
  ## Given a head or tail `value` in the range `0..<2*capacity`, determine its
  ## actual index in storage.
  assertHeadOrTail(value, capacity)
  result =
    if value >= capacity:
      value - capacity
    else:
      value


proc incOrReset*(
  original: int,
  amount: int,
  capacity: int,
): int
  {.inline.} =
  ## Given an `original` head or tail value and an `amount` to increment, either
  ## increment `original` by `amount`, or reset from zero if
  ## `original + amount >= 2 * capacity`.
  assertHeadOrTail(original, capacity)
  assert(amount <= capacity)
  result = original + amount
  if unlikely(result >= 2 * capacity):
    result -= 2 * capacity


proc used*(
  head: int,
  tail: int,
  capacity: int,
): int
  {.inline.} =
  ## Determine how many slots are taken in storage given `head`, `tail`, and
  ## `capacity` values.
  assertHeadOrTail(head, capacity)
  assertHeadOrTail(tail, capacity)

  result = tail - head

  if result < 0:
    result += 2 * capacity


proc available*(
  head: int,
  tail: int,
  capacity: int,
): int
  {.inline.} =
  ## Determine how many slots are available in storage given `head`, `tail`, and
  ## `capacity` values.
  return capacity - used(head, tail, capacity)


proc full*(
  head: int,
  tail: int,
  capacity: int,
): bool
  {.inline.} =
  assertHeadOrTail(head, capacity)
  assertHeadOrTail(tail, capacity)
  ## Determine if storage is full given `head`, `tail`, and `capacity` values.
  return abs(tail - head) == capacity


proc empty*(
  head: int,
  tail: int,
): bool
  {.inline.} =
  ## Determine if storage is empty given `head` and `tail` values.
  return head == tail
