## Operations used internally by various queue implementations.


proc validateHeadOrTail*(
  value: int,
  capacity: int,
): bool
  {.inline.} =
  ## Assert that the given `value` is in the range `0..<2*capacity`.
  return (value in 0..<2*capacity)


proc validateHeadAndTail*(
  head: int,
  tail: int,
  capacity: int,
): bool
  {.inline.} =
  ## Assert that the given `head` and `tail` values are valid for the given
  ## `capacity`.
  assert validateHeadOrTail(head, capacity)
  assert validateHeadOrTail(tail, capacity)
  var count = tail - head
  if count < 0:
    # Case when front in [Capacity, 2*Capacity)
    # and tail in [0, Capacity) range
    # for example for a queue of capacity 7 that rolled twice:
    #
    # | 14 |   |   | 10 | 11 | 12 | 13 |
    #      ^       ^
    #       back    front
    #
    # front is at index 10 (real 3)
    # back is at index 15 (real 1)
    # back - front + capacity = 1 - 3 + 7 = 5
    count += 2 * capacity

  result = count >= 0 and count <= capacity


proc used*(
  head: int,
  tail: int,
  capacity: int,
): int
  {.inline.} =
  ## Determine how many slots are taken in storage given `head`, `tail`, and
  ## `capacity` values.
  # assert validateHeadAndTail(head, tail, capacity)
  assert validateHeadOrTail(head, capacity)
  assert validateHeadOrTail(tail, capacity)
  result = tail - head
  if result < 0:
    # Case when front in [Capacity, 2*Capacity)
    # and tail in [0, Capacity) range
    # for example for a queue of capacity 7 that rolled twice:
    #
    # | 14 |   |   | 10 | 11 | 12 | 13 |
    #      ^       ^
    #       back    front
    #
    # front is at index 10 (real 3)
    # back is at index 15 (real 1)
    # back - front + capacity = 1 - 3 + 7 = 5
    result += 2 * capacity


proc available*(
  head: int,
  tail: int,
  capacity: int,
): int
  {.inline.} =
  ## Determine how many slots are available in storage given `head`, `tail`, and
  ## `capacity` values.
  result = capacity - used(head, tail, capacity)


proc index*(
  value: int,
  capacity: int,
): int
  {.inline.} =
  ## Given a head or tail `value` in the range `0..<2*capacity`, determine its
  ## actual index in storage.
  assert validateHeadOrTail(value, capacity)
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
  assert validateHeadOrTail(original, capacity)
  assert amount in 0..capacity
  result = original + amount
  if result >= 2 * capacity:
    result -= 2 * capacity


proc full*(
  head: int,
  tail: int,
  capacity: int,
): bool
  {.inline.} =
  ## Determine if storage is full given `head`, `tail`, and `capacity` values.
  return used(head, tail, capacity) >= capacity


proc empty*(
  head: int,
  tail: int,
  capacity: int,
): bool
  {.inline.} =
  ## Determine if storage is empty given `head` and `tail` values.
  # assert validateHeadAndTail(head, tail, capacity)
  assert validateHeadOrTail(head, capacity)
  assert validateHeadOrTail(tail, capacity)
  return head == tail

