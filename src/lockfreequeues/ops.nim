# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## Operations used internally by various queue implementations.
import ./exceptions

proc index*(
  value: int,
  capacity: int,
): int {.noSideEffect, raises: [QueueIndexError].} =
  ## Given a head or tail `value` in the range `0..<2*capacity`, determine its
  ## actual index in storage.
  if unlikely(value < 0 or value >= 2*capacity):
    raise newException(QueueIndexError, "value=" & $value & " must be > 0 and <= 2*" & $capacity)
  elif value >= capacity:
    result = value - capacity
  else:
    result = value


proc incOrReset*(
  original: int,
  amount: int,
  capacity: int,
): int {.noSideEffect, raises: [QueueIndexError].} =
  ## Given an `original` head or tail value and an `amount` to increment, either
  ## increment `original` by `amount`, or reset from zero if
  ## `original + amount >= 2 * capacity`.
  if unlikely(original < 0 or original >= 2*capacity):
    raise newException(QueueIndexError, "original=" & $original & " must be > 0 and <= 2*" & $capacity)
  elif unlikely(amount notin 0..capacity):
    raise newException(QueueIndexError, "amount=" & $amount & " must be > 0 and < " & $capacity)
  result = original + amount
  if unlikely(result >= 2 * capacity):
    result -= 2 * capacity


proc used*(
  head: int,
  tail: int,
  capacity: int,
): int {.noSideEffect, raises: [QueueIndexError].} =
  ## Determine how many slots are taken in storage given `head`, `tail`, and
  ## `capacity` values.

  if unlikely(capacity == 0):
    # special case for 0-sized queue
    if unlikely(head != 0):
      raise newException(QueueIndexError, "head=" & $head & " must be 0 when capacity=0")
    elif unlikely(tail != 0):
      raise newException(QueueIndexError, "tail=" & $tail & " must be 0 when capacity=0")
  else:
    if unlikely(capacity < 0):
      raise newException(QueueIndexError, "capacity=" & $capacity & " must be > 0")
    elif unlikely(head < 0 or head >= 2*capacity):
      raise newException(QueueIndexError, "head=" & $head & " must be > 0 and <= 2*" & $capacity)
    elif unlikely(tail < 0 or tail >= 2*capacity):
      raise newException(QueueIndexError, "tail=" & $tail & " must be > 0 and <= 2*" & $capacity)

  if tail >= capacity:
    if head >= capacity:
      result = tail - head
    else:
      result = (capacity - head) + (tail - capacity)
  else:
    if head >= capacity:
      result = (tail + (2*capacity)) - head
    else:
      result = tail - head
  if unlikely(result < 0 or result > capacity):
    raise newException(QueueIndexError, "result=" & $result & " must be <= capacity=" & $capacity)


proc available*(
  head: int,
  tail: int,
  capacity: int,
): int {.noSideEffect, raises: [QueueIndexError].} =
  ## Determine how many slots are available in storage given `head`, `tail`, and
  ## `capacity` values.
  result = capacity - used(head, tail, capacity)


proc full*(
  head: int,
  tail: int,
  capacity: int,
): bool {.noSideEffect, raises: [QueueIndexError].} =
  ## Determine if storage is full given `head`, `tail`, and `capacity` values.
  return used(head, tail, capacity) >= capacity


proc empty*(
  head: int,
  tail: int,
  capacity: int,
): bool {.noSideEffect, raises: [QueueIndexError].} =
  ## Determine if storage is empty given `head` and `tail` values.
  # if unlikely(capacity == 0):
  #   # special case for 0-sized queue
  #   if unlikely(head != 0):
  #     raise newException(QueueIndexError, "head=" & $head & " must be 0 when capacity=0")
  #   elif unlikely(tail != 0):
  #     raise newException(QueueIndexError, "tail=" & $tail & " must be 0 when capacity=0")
  # else:
  #   if unlikely(capacity < 0):
  #     raise newException(QueueIndexError, "capacity=" & $capacity & " must be > 0")
  #   elif unlikely(head < 0 or head >= 2*capacity):
  #     raise newException(QueueIndexError, "head=" & $head & " must be > 0 and <= 2*" & $capacity)
  #   elif unlikely(tail < 0 or tail >= 2*capacity):
  #     raise newException(QueueIndexError, "tail=" & $tail & " must be > 0 and <= 2*" & $capacity)
  # return head == tail
  return used(head, tail, capacity) == 0
