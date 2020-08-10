# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest

import lockfreequeues/ops


when (NimMajor, NimMinor) < (1, 3):
  type AssertionDefect = AssertionError


suite "index(value, capacity)":
  test "value notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard index(-1, 4)
    expect(AssertionDefect):
      discard index(8, 4)

  test "capacity <= 0 raises AssertionDefect":
    expect(AssertionDefect):
      discard(index(0, -1))
    expect(AssertionDefect):
      discard(index(0, 0))

  test "all":
    for value in 0..<4:
      check(index(value, 4) == value)
    for value in 4..<8:
      check(index(value, 4) == value - 4)


suite "incOrReset(original, amount, capacity)":
  test "original notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard incOrReset(-1, 0, 4)
    expect(AssertionDefect):
      discard incOrReset(8, 0, 4)

  test "amount notin 0..capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard incOrReset(0, -1, 4)
    expect(AssertionDefect):
      discard incOrReset(0, 8, 4)

  test "capacity <= 0 raises AssertionDefect":
    expect(AssertionDefect):
      discard(incOrReset(0, 1, -1))
    expect(AssertionDefect):
      discard(incOrReset(0, 1, 0))

  test "all":
    for original in 0..<8:
      for amount in 0..4:
        let expected =
          if original + amount < 8:
            original + amount
          else:
            (original + amount) - 8
        check(incOrReset(original, amount, 4) == expected)


suite "used(head, tail, capacity)":
  test "head notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard used(-1, 0, 4)
    expect(AssertionDefect):
      discard used(8, 0, 4)

  test "tail notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard used(0, -1, 4)

    expect(AssertionDefect):
      discard used(0, 8, 4)

  test "capacity <= 0 raises AssertionDefect":
    expect(AssertionDefect):
      discard(used(0, 0, -1))
    expect(AssertionDefect):
      discard(used(0, 0, 0))

  test "all":
    check(used(0, 0, 4) == 0)
    check(used(0, 1, 4) == 1)
    check(used(0, 2, 4) == 2)
    check(used(0, 3, 4) == 3)
    check(used(0, 4, 4) == 4)
    check(used(0, 5, 4) == 5)
    check(used(0, 6, 4) == 6)
    check(used(0, 7, 4) == 7)
    check(used(1, 0, 4) == 3)
    check(used(1, 1, 4) == 0)
    check(used(1, 2, 4) == 1)
    check(used(1, 3, 4) == 2)
    check(used(1, 4, 4) == 3)
    check(used(1, 5, 4) == 4)
    check(used(1, 6, 4) == 5)
    check(used(1, 7, 4) == 6)
    check(used(2, 0, 4) == 2)
    check(used(2, 1, 4) == 3)
    check(used(2, 2, 4) == 0)
    check(used(2, 3, 4) == 1)
    check(used(2, 4, 4) == 2)
    check(used(2, 5, 4) == 3)
    check(used(2, 6, 4) == 4)
    check(used(2, 7, 4) == 5)
    check(used(3, 0, 4) == 1)
    check(used(3, 1, 4) == 2)
    check(used(3, 2, 4) == 3)
    check(used(3, 3, 4) == 0)
    check(used(3, 4, 4) == 1)
    check(used(3, 5, 4) == 2)
    check(used(3, 6, 4) == 3)
    check(used(3, 7, 4) == 4)
    check(used(4, 0, 4) == 4)
    check(used(4, 1, 4) == 5)
    check(used(4, 2, 4) == 6)
    check(used(4, 3, 4) == 7)
    check(used(4, 4, 4) == 0)
    check(used(4, 5, 4) == 1)
    check(used(4, 6, 4) == 2)
    check(used(4, 7, 4) == 3)
    check(used(5, 0, 4) == 3)
    check(used(5, 1, 4) == 4)
    check(used(5, 2, 4) == 5)
    check(used(5, 3, 4) == 6)
    check(used(5, 4, 4) == 3)
    check(used(5, 5, 4) == 0)
    check(used(5, 6, 4) == 1)
    check(used(5, 7, 4) == 2)
    check(used(6, 0, 4) == 2)
    check(used(6, 1, 4) == 3)
    check(used(6, 2, 4) == 4)
    check(used(6, 3, 4) == 5)
    check(used(6, 4, 4) == 2)
    check(used(6, 5, 4) == 3)
    check(used(6, 6, 4) == 0)
    check(used(6, 7, 4) == 1)
    check(used(7, 0, 4) == 1)
    check(used(7, 1, 4) == 2)
    check(used(7, 2, 4) == 3)
    check(used(7, 3, 4) == 4)
    check(used(7, 4, 4) == 1)
    check(used(7, 5, 4) == 2)
    check(used(7, 6, 4) == 3)
    check(used(7, 7, 4) == 0)


suite "available(head, tail, capacity)":

  test "head notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard available(-1, 0, 4)
    expect(AssertionDefect):
      discard available(8, 0, 4)

  test "tail notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard available(0, -1, 4)
    expect(AssertionDefect):
      discard available(0, 8, 4)

  test "capacity <= 0 raises AssertionDefect":
    expect(AssertionDefect):
      discard(available(0, 0, -1))
    expect(AssertionDefect):
      discard(available(0, 0, 0))

  test "all":
    check(available(0, 0, 4) == 4)
    check(available(0, 1, 4) == 3)
    check(available(0, 2, 4) == 2)
    check(available(0, 3, 4) == 1)
    check(available(0, 4, 4) == 0)
    check(available(0, 5, 4) == -1)
    check(available(0, 6, 4) == -2)
    check(available(0, 7, 4) == -3)
    check(available(1, 0, 4) == 1)
    check(available(1, 1, 4) == 4)
    check(available(1, 2, 4) == 3)
    check(available(1, 3, 4) == 2)
    check(available(1, 4, 4) == 1)
    check(available(1, 5, 4) == 0)
    check(available(1, 6, 4) == -1)
    check(available(1, 7, 4) == -2)
    check(available(2, 0, 4) == 2)
    check(available(2, 1, 4) == 1)
    check(available(2, 2, 4) == 4)
    check(available(2, 3, 4) == 3)
    check(available(2, 4, 4) == 2)
    check(available(2, 5, 4) == 1)
    check(available(2, 6, 4) == 0)
    check(available(2, 7, 4) == -1)
    check(available(3, 0, 4) == 3)
    check(available(3, 1, 4) == 2)
    check(available(3, 2, 4) == 1)
    check(available(3, 3, 4) == 4)
    check(available(3, 4, 4) == 3)
    check(available(3, 5, 4) == 2)
    check(available(3, 6, 4) == 1)
    check(available(3, 7, 4) == 0)
    check(available(4, 0, 4) == 0)
    check(available(4, 1, 4) == -1)
    check(available(4, 2, 4) == -2)
    check(available(4, 3, 4) == -3)
    check(available(4, 4, 4) == 4)
    check(available(4, 5, 4) == 3)
    check(available(4, 6, 4) == 2)
    check(available(4, 7, 4) == 1)
    check(available(5, 0, 4) == 1)
    check(available(5, 1, 4) == 0)
    check(available(5, 2, 4) == -1)
    check(available(5, 3, 4) == -2)
    check(available(5, 4, 4) == 1)
    check(available(5, 5, 4) == 4)
    check(available(5, 6, 4) == 3)
    check(available(5, 7, 4) == 2)
    check(available(6, 0, 4) == 2)
    check(available(6, 1, 4) == 1)
    check(available(6, 2, 4) == 0)
    check(available(6, 3, 4) == -1)
    check(available(6, 4, 4) == 2)
    check(available(6, 5, 4) == 1)
    check(available(6, 6, 4) == 4)
    check(available(6, 7, 4) == 3)
    check(available(7, 0, 4) == 3)
    check(available(7, 1, 4) == 2)
    check(available(7, 2, 4) == 1)
    check(available(7, 3, 4) == 0)
    check(available(7, 4, 4) == 3)
    check(available(7, 5, 4) == 2)
    check(available(7, 6, 4) == 1)
    check(available(7, 7, 4) == 4)


suite "full(head, tail, capacity)":

  test "head notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard full(-1, 0, 4)
    expect(AssertionDefect):
      discard full(8, 0, 4)

  test "tail notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard full(0, -1, 4)
    expect(AssertionDefect):
      discard full(0, 8, 4)

  test "capacity <= 0 raises AssertionDefect":
    expect(AssertionDefect):
      discard(full(0, 0, -1))
    expect(AssertionDefect):
      discard(full(0, 0, 0))

  test "all":
    check(full(0, 0, 4) == false)
    check(full(0, 1, 4) == false)
    check(full(0, 2, 4) == false)
    check(full(0, 3, 4) == false)
    check(full(0, 4, 4) == true)
    check(full(0, 5, 4) == true)
    check(full(0, 6, 4) == true)
    check(full(0, 7, 4) == true)
    check(full(1, 0, 4) == false)
    check(full(1, 1, 4) == false)
    check(full(1, 2, 4) == false)
    check(full(1, 3, 4) == false)
    check(full(1, 4, 4) == false)
    check(full(1, 5, 4) == true)
    check(full(1, 6, 4) == true)
    check(full(1, 7, 4) == true)
    check(full(2, 0, 4) == false)
    check(full(2, 1, 4) == false)
    check(full(2, 2, 4) == false)
    check(full(2, 3, 4) == false)
    check(full(2, 4, 4) == false)
    check(full(2, 5, 4) == false)
    check(full(2, 6, 4) == true)
    check(full(2, 7, 4) == true)
    check(full(3, 0, 4) == false)
    check(full(3, 1, 4) == false)
    check(full(3, 2, 4) == false)
    check(full(3, 3, 4) == false)
    check(full(3, 4, 4) == false)
    check(full(3, 5, 4) == false)
    check(full(3, 6, 4) == false)
    check(full(3, 7, 4) == true)
    check(full(4, 0, 4) == true)
    check(full(4, 1, 4) == false)
    check(full(4, 2, 4) == false)
    check(full(4, 3, 4) == false)
    check(full(4, 4, 4) == false)
    check(full(4, 5, 4) == false)
    check(full(4, 6, 4) == false)
    check(full(4, 7, 4) == false)
    check(full(5, 0, 4) == true)
    check(full(5, 1, 4) == true)
    check(full(5, 2, 4) == false)
    check(full(5, 3, 4) == false)
    check(full(5, 4, 4) == false)
    check(full(5, 5, 4) == false)
    check(full(5, 6, 4) == false)
    check(full(5, 7, 4) == false)
    check(full(6, 0, 4) == true)
    check(full(6, 1, 4) == true)
    check(full(6, 2, 4) == true)
    check(full(6, 3, 4) == false)
    check(full(6, 4, 4) == false)
    check(full(6, 5, 4) == false)
    check(full(6, 6, 4) == false)
    check(full(6, 7, 4) == false)
    check(full(7, 0, 4) == true)
    check(full(7, 1, 4) == true)
    check(full(7, 2, 4) == true)
    check(full(7, 3, 4) == true)
    check(full(7, 4, 4) == false)
    check(full(7, 5, 4) == false)
    check(full(7, 6, 4) == false)
    check(full(7, 7, 4) == false)


suite "empty(head, tail, 4)":

  test "head notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard empty(-1, 0, 4)
    expect(AssertionDefect):
      discard empty(8, 0, 4)

  test "tail notin 0..<2*capacity raises AssertionDefect":
    expect(AssertionDefect):
      discard empty(0, -1, 4)
    expect(AssertionDefect):
      discard empty(0, 8, 4)

  test "all":
    check(empty(0, 0, 4) == true)
    check(empty(0, 1, 4) == false)
    check(empty(0, 2, 4) == false)
    check(empty(0, 3, 4) == false)
    check(empty(0, 4, 4) == false)
    check(empty(0, 5, 4) == false)
    check(empty(0, 6, 4) == false)
    check(empty(0, 7, 4) == false)
    check(empty(1, 0, 4) == false)
    check(empty(1, 1, 4) == true)
    check(empty(1, 2, 4) == false)
    check(empty(1, 3, 4) == false)
    check(empty(1, 4, 4) == false)
    check(empty(1, 5, 4) == false)
    check(empty(1, 6, 4) == false)
    check(empty(1, 7, 4) == false)
    check(empty(2, 0, 4) == false)
    check(empty(2, 1, 4) == false)
    check(empty(2, 2, 4) == true)
    check(empty(2, 3, 4) == false)
    check(empty(2, 4, 4) == false)
    check(empty(2, 5, 4) == false)
    check(empty(2, 6, 4) == false)
    check(empty(2, 7, 4) == false)
    check(empty(3, 0, 4) == false)
    check(empty(3, 1, 4) == false)
    check(empty(3, 2, 4) == false)
    check(empty(3, 3, 4) == true)
    check(empty(3, 4, 4) == false)
    check(empty(3, 5, 4) == false)
    check(empty(3, 6, 4) == false)
    check(empty(3, 7, 4) == false)
    check(empty(4, 0, 4) == false)
    check(empty(4, 1, 4) == false)
    check(empty(4, 2, 4) == false)
    check(empty(4, 3, 4) == false)
    check(empty(4, 4, 4) == true)
    check(empty(4, 5, 4) == false)
    check(empty(4, 6, 4) == false)
    check(empty(4, 7, 4) == false)
    check(empty(5, 0, 4) == false)
    check(empty(5, 1, 4) == false)
    check(empty(5, 2, 4) == false)
    check(empty(5, 3, 4) == false)
    check(empty(5, 4, 4) == false)
    check(empty(5, 5, 4) == true)
    check(empty(5, 6, 4) == false)
    check(empty(5, 7, 4) == false)
    check(empty(6, 0, 4) == false)
    check(empty(6, 1, 4) == false)
    check(empty(6, 2, 4) == false)
    check(empty(6, 3, 4) == false)
    check(empty(6, 4, 4) == false)
    check(empty(6, 5, 4) == false)
    check(empty(6, 6, 4) == true)
    check(empty(6, 7, 4) == false)
    check(empty(7, 0, 4) == false)
    check(empty(7, 1, 4) == false)
    check(empty(7, 2, 4) == false)
    check(empty(7, 3, 4) == false)
    check(empty(7, 4, 4) == false)
    check(empty(7, 5, 4) == false)
    check(empty(7, 6, 4) == false)
    check(empty(7, 7, 4) == true)
