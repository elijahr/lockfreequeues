# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest

import lockfreequeues/[exceptions, ops]


proc test_invalid[T](op: proc(head: int, tail: int, capacity: int): T): void {.discardable.} =
  # echo "testing " & repr(op)
  expect(QueueIndexError):
    discard op(0, 5, 4)
  expect(QueueIndexError):
    discard op(0, 6, 4)
  expect(QueueIndexError):
    discard op(0, 7, 4)
  expect(QueueIndexError):
    discard op(1, 0, 4)
  expect(QueueIndexError):
    discard op(1, 6, 4)
  expect(QueueIndexError):
    discard op(1, 7, 4)
  expect(QueueIndexError):
    discard op(2, 0, 4)
  expect(QueueIndexError):
    discard op(2, 1, 4)
  expect(QueueIndexError):
    discard op(2, 7, 4)
  expect(QueueIndexError):
    discard op(3, 0, 4)
  expect(QueueIndexError):
    discard op(3, 1, 4)
  expect(QueueIndexError):
    discard op(3, 2, 4)
  expect(QueueIndexError):
    discard op(4, 1, 4)
  expect(QueueIndexError):
    discard op(4, 2, 4)
  expect(QueueIndexError):
    discard op(4, 3, 4)
  expect(QueueIndexError):
    discard op(5, 2, 4)
  expect(QueueIndexError):
    discard op(5, 3, 4)
  expect(QueueIndexError):
    discard op(5, 4, 4)
  expect(QueueIndexError):
    discard op(6, 3, 4)
  expect(QueueIndexError):
    discard op(6, 4, 4)
  expect(QueueIndexError):
    discard op(6, 5, 4)
  expect(QueueIndexError):
    discard op(7, 4, 4)
  expect(QueueIndexError):
    discard op(7, 5, 4)
  expect(QueueIndexError):
    discard op(7, 6, 4)
  expect(QueueIndexError):
    discard op(8, -1, 4)
  expect(QueueIndexError):
    discard op(8, 0, 4)
  expect(QueueIndexError):
    discard op(8, 1, 4)
  expect(QueueIndexError):
    discard op(8, 2, 4)
  expect(QueueIndexError):
    discard op(8, 3, 4)
  expect(QueueIndexError):
    discard op(8, 4, 4)
  expect(QueueIndexError):
    discard op(8, 5, 4)
  expect(QueueIndexError):
    discard op(8, 6, 4)
  expect(QueueIndexError):
    discard op(8, 7, 4)
  expect(QueueIndexError):
    discard op(8, 8, 4)
  expect(QueueIndexError):
    discard op(-1, -1, 4)
  expect(QueueIndexError):
    discard op(-1, 0, 4)
  expect(QueueIndexError):
    discard op(-1, 1, 4)
  expect(QueueIndexError):
    discard op(-1, 2, 4)
  expect(QueueIndexError):
    discard op(-1, 3, 4)
  expect(QueueIndexError):
    discard op(-1, 4, 4)
  expect(QueueIndexError):
    discard op(-1, 5, 4)
  expect(QueueIndexError):
    discard op(-1, 6, 4)
  expect(QueueIndexError):
    discard op(-1, 7, 4)
  expect(QueueIndexError):
    discard op(-1, 8, 4)
  expect(QueueIndexError):
    discard op(-1, -1, -1)
  expect(QueueIndexError):
    discard op(-1, 0, -1)
  expect(QueueIndexError):
    discard op(-1, 1, -1)
  expect(QueueIndexError):
    discard op(0, -1, -1)
  expect(QueueIndexError):
    discard op(0, 0, -1)
  expect(QueueIndexError):
    discard op(0, 1, -1)
  expect(QueueIndexError):
    discard op(1, -1, -1)
  expect(QueueIndexError):
    discard op(1, 0, -1)
  expect(QueueIndexError):
    discard op(1, 1, -1)
  expect(QueueIndexError):
    discard op(-1, -1, 0)
  expect(QueueIndexError):
    discard op(-1, 0, 0)
  expect(QueueIndexError):
    discard op(-1, 1, 0)
  expect(QueueIndexError):
    discard op(0, -1, 0)
  expect(QueueIndexError):
    discard op(0, 1, 0)
  expect(QueueIndexError):
    discard op(1, -1, 0)
  expect(QueueIndexError):
    discard op(1, 0, 0)
  expect(QueueIndexError):
    discard op(1, 1, 0)


suite "index(value, capacity)":
  test "value in 0..<capacity":
    for value in 0..<4:
      check(index(value, 4) == value)

  test "value in 4..<2*capacity":
    for value in 4..<8:
      check(index(value, 4) == value - 4)

  test "value >2*capacity":
    for value in 8..<32:
      expect(QueueIndexError):
        discard index(value, 4)


suite "incOrReset(original, amount, capacity)":
  test "original+amount < 2*capacity":
    check(incOrReset(0, 0, 4) == 0)
    check(incOrReset(0, 1, 4) == 1)
    check(incOrReset(0, 2, 4) == 2)
    check(incOrReset(0, 3, 4) == 3)
    check(incOrReset(0, 4, 4) == 4)
    check(incOrReset(1, 0, 4) == 1)
    check(incOrReset(1, 1, 4) == 2)
    check(incOrReset(1, 2, 4) == 3)
    check(incOrReset(1, 3, 4) == 4)
    check(incOrReset(1, 4, 4) == 5)
    check(incOrReset(2, 0, 4) == 2)
    check(incOrReset(2, 1, 4) == 3)
    check(incOrReset(2, 2, 4) == 4)
    check(incOrReset(2, 3, 4) == 5)
    check(incOrReset(2, 4, 4) == 6)
    check(incOrReset(3, 0, 4) == 3)
    check(incOrReset(3, 1, 4) == 4)
    check(incOrReset(3, 2, 4) == 5)
    check(incOrReset(3, 3, 4) == 6)
    check(incOrReset(3, 4, 4) == 7)
    check(incOrReset(4, 0, 4) == 4)
    check(incOrReset(4, 1, 4) == 5)
    check(incOrReset(4, 2, 4) == 6)
    check(incOrReset(4, 3, 4) == 7)
    check(incOrReset(5, 0, 4) == 5)
    check(incOrReset(5, 1, 4) == 6)
    check(incOrReset(5, 2, 4) == 7)
    check(incOrReset(6, 0, 4) == 6)
    check(incOrReset(6, 1, 4) == 7)
    check(incOrReset(7, 0, 4) == 7)

  test "original+amount >= 2*capacity":
    check(incOrReset(4, 4, 4) == 0)
    check(incOrReset(5, 3, 4) == 0)
    check(incOrReset(5, 4, 4) == 1)
    check(incOrReset(6, 2, 4) == 0)
    check(incOrReset(6, 3, 4) == 1)
    check(incOrReset(6, 4, 4) == 2)
    check(incOrReset(7, 1, 4) == 0)
    check(incOrReset(7, 2, 4) == 1)
    check(incOrReset(7, 3, 4) == 2)
    check(incOrReset(7, 4, 4) == 3)

suite "used(head, tail, capacity)":
  test "valid":
    check(used(0, 0, 4) == 0)
    check(used(0, 1, 4) == 1)
    check(used(0, 2, 4) == 2)
    check(used(0, 3, 4) == 3)
    check(used(0, 4, 4) == 4)
    check(used(1, 1, 4) == 0)
    check(used(1, 2, 4) == 1)
    check(used(1, 3, 4) == 2)
    check(used(1, 4, 4) == 3)
    check(used(1, 5, 4) == 4)
    check(used(2, 2, 4) == 0)
    check(used(2, 3, 4) == 1)
    check(used(2, 4, 4) == 2)
    check(used(2, 5, 4) == 3)
    check(used(2, 6, 4) == 4)
    check(used(3, 3, 4) == 0)
    check(used(3, 4, 4) == 1)
    check(used(3, 5, 4) == 2)
    check(used(3, 6, 4) == 3)
    check(used(3, 7, 4) == 4)
    check(used(4, 0, 4) == 4)
    check(used(4, 4, 4) == 0)
    check(used(4, 5, 4) == 1)
    check(used(4, 6, 4) == 2)
    check(used(4, 7, 4) == 3)
    check(used(5, 0, 4) == 3)
    check(used(5, 1, 4) == 4)
    check(used(5, 5, 4) == 0)
    check(used(5, 6, 4) == 1)
    check(used(5, 7, 4) == 2)
    check(used(6, 0, 4) == 2)
    check(used(6, 1, 4) == 3)
    check(used(6, 2, 4) == 4)
    check(used(6, 6, 4) == 0)
    check(used(6, 7, 4) == 1)
    check(used(7, 0, 4) == 1)
    check(used(7, 1, 4) == 2)
    check(used(7, 2, 4) == 3)
    check(used(7, 3, 4) == 4)
    check(used(7, 7, 4) == 0)
    check(used(0, 0, 0) == 0)

  test "invalid":
    test_invalid[int](used)


suite "available(head, tail, capacity)":
  test "valid":
    check(available(0, 0, 4) == 4)
    check(available(0, 1, 4) == 3)
    check(available(0, 2, 4) == 2)
    check(available(0, 3, 4) == 1)
    check(available(0, 4, 4) == 0)
    check(available(1, 1, 4) == 4)
    check(available(1, 2, 4) == 3)
    check(available(1, 3, 4) == 2)
    check(available(1, 4, 4) == 1)
    check(available(1, 5, 4) == 0)
    check(available(2, 2, 4) == 4)
    check(available(2, 3, 4) == 3)
    check(available(2, 4, 4) == 2)
    check(available(2, 5, 4) == 1)
    check(available(2, 6, 4) == 0)
    check(available(3, 3, 4) == 4)
    check(available(3, 4, 4) == 3)
    check(available(3, 5, 4) == 2)
    check(available(3, 6, 4) == 1)
    check(available(3, 7, 4) == 0)
    check(available(4, 0, 4) == 0)
    check(available(4, 4, 4) == 4)
    check(available(4, 5, 4) == 3)
    check(available(4, 6, 4) == 2)
    check(available(4, 7, 4) == 1)
    check(available(5, 0, 4) == 1)
    check(available(5, 1, 4) == 0)
    check(available(5, 5, 4) == 4)
    check(available(5, 6, 4) == 3)
    check(available(5, 7, 4) == 2)
    check(available(6, 0, 4) == 2)
    check(available(6, 1, 4) == 1)
    check(available(6, 2, 4) == 0)
    check(available(6, 6, 4) == 4)
    check(available(6, 7, 4) == 3)
    check(available(7, 0, 4) == 3)
    check(available(7, 1, 4) == 2)
    check(available(7, 2, 4) == 1)
    check(available(7, 3, 4) == 0)
    check(available(7, 7, 4) == 4)
    check(available(0, 0, 0) == 0)

  test "invalid":
    test_invalid[int](available)


suite "full(head, tail, capacity)":
  test "valid":
    check(not full(0, 0, 4))
    check(not full(0, 1, 4))
    check(not full(0, 2, 4))
    check(not full(0, 3, 4))
    check(full(0, 4, 4))
    check(not full(1, 1, 4))
    check(not full(1, 2, 4))
    check(not full(1, 3, 4))
    check(not full(1, 4, 4))
    check(full(1, 5, 4))
    check(not full(2, 2, 4))
    check(not full(2, 3, 4))
    check(not full(2, 4, 4))
    check(not full(2, 5, 4))
    check(full(2, 6, 4))
    check(not full(3, 3, 4))
    check(not full(3, 4, 4))
    check(not full(3, 5, 4))
    check(not full(3, 6, 4))
    check(full(3, 7, 4))
    check(full(4, 0, 4))
    check(not full(4, 4, 4))
    check(not full(4, 5, 4))
    check(not full(4, 6, 4))
    check(not full(4, 7, 4))
    check(not full(5, 0, 4))
    check(full(5, 1, 4))
    check(not full(5, 5, 4))
    check(not full(5, 6, 4))
    check(not full(5, 7, 4))
    check(not full(6, 0, 4))
    check(not full(6, 1, 4))
    check(full(6, 2, 4))
    check(not full(6, 6, 4))
    check(not full(6, 7, 4))
    check(not full(7, 0, 4))
    check(not full(7, 1, 4))
    check(not full(7, 2, 4))
    check(full(7, 3, 4))
    check(not full(7, 7, 4))
    check(full(0, 0, 0))

  test "invalid":
    test_invalid[bool](full)


suite "empty(head, tail, 4)":
  test "valid":
    discard

  test "invalid":
    test_invalid[bool](empty)
