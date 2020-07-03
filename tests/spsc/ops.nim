# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest

import lockfreequeues/spsc/ops


suite "index(value, capacity)":

  test "value < 0 raises AssertionError":
    expect(AssertionError):
      discard index(-1, 4)

  test "value >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard index(8, 4)

  test "basic":
    for value in 0..<4:
      check(index(value, 4) == value)
    for value in 4..<8:
      check(index(value, 4) == value - 4)


suite "incOrReset(original, amount, capacity)":

  test "original < 0 raises AssertionError":
    expect(AssertionError):
      discard incOrReset(-1, 1, 4)

  test "original >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard incOrReset(16, 1, 4)

  test "amount < 0 raises AssertionError":
    expect(AssertionError):
      discard incOrReset(0, -1, 4)

  test "amount >= capacity raises AssertionError":
    expect(AssertionError):
      discard incOrReset(0, 5, 4)

  test "basic":
    for original in 0..<8:
      for amount in 0..4:
        let expected =
          if original + amount < 8:
            original + amount
          else:
            (original + amount) - 8
        check(incOrReset(original, amount, 4) == expected)


suite "used(head, tail, capacity)":

  test "head < 0 raises AssertionError":
    expect(AssertionError):
      discard used(-1, 0, 4)

  test "head >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard used(8, 0, 4)

  test "tail < 0 raises AssertionError":
    expect(AssertionError):
      discard used(0, -1, 4)

  test "tail >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard used(0, 8, 4)

  test "basic":
    for head in 0..<8:
      for tail in 0..<8:
        let expected =
          if tail - head < 0:
            (tail - head) + 8
          else:
            tail - head
        check(used(head, tail, 4) == expected)


suite "available(head, tail, capacity)":

  test "head < 0 raises AssertionError":
    expect(AssertionError):
      discard available(-1, 0, 4)

  test "head >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard available(8, 0, 4)

  test "tail < 0 raises AssertionError":
    expect(AssertionError):
      discard available(0, -1, 4)

  test "tail >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard available(0, 8, 4)

  test "basic":
    for head in 0..<8:
      for tail in 0..<8:
        let used =
          if tail - head < 0:
            (tail - head) + 8
          else:
            tail - head
        let expected = 4 - used
        check(available(head, tail, 4) == expected)


suite "full(head, tail, capacity)":

  test "head < 0 raises AssertionError":
    expect(AssertionError):
      discard full(-1, 0, 4)

  test "head >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard full(8, 0, 4)

  test "tail < 0 raises AssertionError":
    expect(AssertionError):
      discard full(0, -1, 4)

  test "tail >= 2 * capacity raises AssertionError":
    expect(AssertionError):
      discard full(0, 8, 4)

  test "basic":
    for head in 0..<8:
      for tail in 0..<8:
        let used =
          if tail - head < 0:
            (tail - head) + 8
          else:
            tail - head
        let expected = used == 4
        check(full(head, tail, 4) == expected)


suite "empty(head, tail)":

  test "basic":
    for head in 0..<8:
      for tail in 0..<8:
        check(empty(head, tail) == (head == tail))
