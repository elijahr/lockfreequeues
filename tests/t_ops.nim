# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest

import lockfreequeues/ops


when (NimMajor, NimMinor) < (1, 3):
  type AssertionDefect = AssertionError


suite "ops.index(value, capacity)":

  test "value >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard index(8, 4)

  test "basic":
    for value in 0..<4:
      check(index(value, 4) == value)
    for value in 4..<8:
      check(index(value, 4) == value - 4)


suite "ops.incOrReset(original, amount, capacity)":

  test "original >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard incOrReset(16, 1, 4)

  test "amount >= capacity raises AssertionDefect":
    expect(AssertionDefect):
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


suite "ops.used(head, tail, capacity)":

  test "head >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard used(8, 0, 4)

  test "tail >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard used(0, 8, 4)

  test "basic":
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


suite "ops.available(head, tail, capacity)":

  test "head >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard available(8, 0, 4)

  test "tail >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard available(0, 8, 4)

  test "basic":
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


suite "ops.full(head, tail, capacity)":

  test "head >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard full(8, 0, 4)

  test "tail >= 2 * capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard full(0, 8, 4)

  test "basic":
    check(full(0, 0, 4) == false)
    check(full(0, 1, 4) == false)
    check(full(0, 2, 4) == false)
    check(full(0, 3, 4) == false)
    check(full(0, 4, 4) == true)
    check(full(1, 1, 4) == false)
    check(full(1, 2, 4) == false)
    check(full(1, 3, 4) == false)
    check(full(1, 4, 4) == false)
    check(full(1, 5, 4) == true)
    check(full(2, 2, 4) == false)
    check(full(2, 3, 4) == false)
    check(full(2, 4, 4) == false)
    check(full(2, 5, 4) == false)
    check(full(2, 6, 4) == true)
    check(full(3, 3, 4) == false)
    check(full(3, 4, 4) == false)
    check(full(3, 5, 4) == false)
    check(full(3, 6, 4) == false)
    check(full(3, 7, 4) == true)
    check(full(4, 0, 4) == true)
    check(full(4, 4, 4) == false)
    check(full(4, 5, 4) == false)
    check(full(4, 6, 4) == false)
    check(full(4, 7, 4) == false)
    check(full(5, 0, 4) == false)
    check(full(5, 1, 4) == true)
    check(full(5, 5, 4) == false)
    check(full(5, 6, 4) == false)
    check(full(5, 7, 4) == false)
    check(full(6, 0, 4) == false)
    check(full(6, 1, 4) == false)
    check(full(6, 2, 4) == true)
    check(full(6, 6, 4) == false)
    check(full(6, 7, 4) == false)
    check(full(7, 0, 4) == false)
    check(full(7, 1, 4) == false)
    check(full(7, 2, 4) == false)
    check(full(7, 3, 4) == true)
    check(full(7, 7, 4) == false)


suite "ops.empty(head, tail)":

  test "basic":
    check(empty(0, 0) == true)
    check(empty(0, 1) == false)
    check(empty(0, 2) == false)
    check(empty(0, 3) == false)
    check(empty(0, 4) == false)
    check(empty(1, 1) == true)
    check(empty(1, 2) == false)
    check(empty(1, 3) == false)
    check(empty(1, 4) == false)
    check(empty(1, 5) == false)
    check(empty(2, 2) == true)
    check(empty(2, 3) == false)
    check(empty(2, 4) == false)
    check(empty(2, 5) == false)
    check(empty(2, 6) == false)
    check(empty(3, 3) == true)
    check(empty(3, 4) == false)
    check(empty(3, 5) == false)
    check(empty(3, 6) == false)
    check(empty(3, 7) == false)
    check(empty(4, 0) == false)
    check(empty(4, 4) == true)
    check(empty(4, 5) == false)
    check(empty(4, 6) == false)
    check(empty(4, 7) == false)
    check(empty(5, 0) == false)
    check(empty(5, 1) == false)
    check(empty(5, 5) == true)
    check(empty(5, 6) == false)
    check(empty(5, 7) == false)
    check(empty(6, 0) == false)
    check(empty(6, 1) == false)
    check(empty(6, 2) == false)
    check(empty(6, 6) == true)
    check(empty(6, 7) == false)
    check(empty(7, 0) == false)
    check(empty(7, 1) == false)
    check(empty(7, 2) == false)
    check(empty(7, 3) == false)
    check(empty(7, 7) == true)
