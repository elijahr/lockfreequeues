## Operations used internally by various queue implementations.

proc validateHeadOrTail*(value: int, capacity: int): bool {.inline.} =
  ## Assert that the given `value` is in the range `0..<2*(capacity+1)`.
  ## With N+1 physical slots, logical indices range from 0 to 2N+1.
  return (value in 0 ..< 2 * (capacity + 1))

proc validateHeadAndTail*(head: int, tail: int, capacity: int): bool {.inline.} =
  ## Assert that the given `head` and `tail` values are valid for the given
  ## `capacity`.
  assert validateHeadOrTail(head, capacity)
  assert validateHeadOrTail(tail, capacity)
  var count = tail - head
  if count < 0:
    # Case when head in [capacity+1, 2*(capacity+1))
    # and tail in [0, capacity+1) range
    count += 2 * (capacity + 1)

  result = count >= 0 and count <= capacity

proc used*(head: int, tail: int, capacity: int): int {.inline.} =
  ## Determine how many slots are taken in storage given `head`, `tail`, and
  ## `capacity` values.
  # assert validateHeadAndTail(head, tail, capacity)
  assert validateHeadOrTail(head, capacity)
  assert validateHeadOrTail(tail, capacity)
  result = tail - head
  if result < 0:
    # Case when head in [capacity+1, 2*(capacity+1))
    # and tail in [0, capacity+1) range
    result += 2 * (capacity + 1)

proc available*(head: int, tail: int, capacity: int): int {.inline.} =
  ## Determine how many slots are available in storage given `head`, `tail`, and
  ## `capacity` values.
  result = capacity - used(head, tail, capacity)

proc index*(value: int, capacity: int): int {.inline.} =
  ## Given a head or tail `value` in the range `0..<2*(capacity+1)`, determine its
  ## actual index in storage. Uses mod (capacity + 1) to map to N+1 physical
  ## slots, preventing collision between slots X and X+N.
  result = value mod (capacity + 1)

proc incOrReset*(original: int, amount: int, capacity: int): int {.inline.} =
  ## Given an `original` head or tail value and an `amount` to increment, either
  ## increment `original` by `amount`, or reset from zero if
  ## `original + amount >= 2 * (capacity + 1)`.
  assert validateHeadOrTail(original, capacity)
  assert amount in 0 .. capacity
  result = original + amount
  if result >= 2 * (capacity + 1):
    result -= 2 * (capacity + 1)

proc full*(head: int, tail: int, capacity: int): bool {.inline.} =
  ## Determine if storage is full given `head`, `tail`, and `capacity` values.
  return used(head, tail, capacity) >= capacity

proc empty*(head: int, tail: int, capacity: int): bool {.inline.} =
  ## Determine if storage is empty given `head` and `tail` values.
  # assert validateHeadAndTail(head, tail, capacity)
  assert validateHeadOrTail(head, capacity)
  assert validateHeadOrTail(tail, capacity)
  return head == tail
