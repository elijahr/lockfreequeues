# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Operations used internally by various queue implementations.


proc validateHeadOrTail*(
  value: int,
  capacity: int,
): void
  {.inline.} =
  ## Assert that the given `value` is in the range `0..<2*capacity`.
  if (value notin 0..<2*capacity):
    echo "value=", value, " capacity=", capacity
  assert(value in 0..<2*capacity)


proc index*(
  value: int,
  capacity: int,
): int
  {.inline.} =
  ## Given a head or tail `value` in the range `0..<2*capacity`, determine its
  ## actual index in storage.
  let val = value
  let capacity = capacity
  validateHeadOrTail(val, capacity)
  result =
    if val >= capacity:
      val - capacity
    else:
      val


# proc validateHeadAndTail*(
#   head: int,
#   tail: int,
#   capacity: int,
# ): void
#   {.inline.} =
#   ## Assert that the given `head` and `tail` values represent a valid queue
#   ## state.
#   validateHeadOrTail(head, capacity)
#   validateHeadOrTail(tail, capacity)
#   # if head <= tail:
#   #   if tail - head notin 0..capacity:
#   #     echo "tail=",  tail, ", head=", head, " capacity=", capacity
#   #   assert(tail - head in 0..capacity)
#   # else:
#   #   if head - tail < capacity:
#   #     echo "tail=",  tail, ", head=", head, " capacity=", capacity
#   #   assert(head - tail >= capacity)


proc incOrReset*(
  original: int,
  amount: int,
  capacity: int,
): int
  {.inline.} =
  ## Given an `original` head or tail value and an `amount` to increment, either
  ## increment `original` by `amount`, or reset from zero if
  ## `original + amount >= 2 * capacity`.
  validateHeadOrTail(original, capacity)
  assert(amount in 0..capacity)
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
  validateHeadOrTail(head, capacity)
  validateHeadOrTail(tail, capacity)

  result =
    if tail >= head:
      tail - head
    else:
      capacity - (index(head, capacity) - index(tail, capacity))


proc available*(
  head: int,
  tail: int,
  capacity: int,
): int
  {.inline.} =
  ## Determine how many slots are available in storage given `head`, `tail`, and
  ## `capacity` values.
  result = capacity - used(head, tail, capacity)


proc full*(
  head: int,
  tail: int,
  capacity: int,
): bool
  {.inline.} =
  ## Determine if storage is full given `head`, `tail`, and `capacity` values.
  validateHeadOrTail(head, capacity)
  validateHeadOrTail(tail, capacity)
  return abs(tail - head) >= capacity


proc empty*(
  head: int,
  tail: int,
  capacity: int,
): bool
  {.inline.} =
  ## Determine if storage is empty given `head` and `tail` values.
  validateHeadOrTail(head, capacity)
  validateHeadOrTail(tail, capacity)
  return head == tail

