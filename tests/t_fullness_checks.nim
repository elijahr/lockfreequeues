# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# tests/t_fullness_checks.nim
import unittest2
import lockfreequeues/typestates/virtual_values_n
import lockfreequeues/typestates/virtual_values_n1
import lockfreequeues/typestates/fullness_checks

suite "N-slot fullness (for MPSC/SPMC/MPMC)":

  test "empty when head == tail":
    let head = initRawN[4](0).validate()
    let tail = initRawN[4](0).validate()
    check(emptyN(head, tail))
    check(not fullN(head, tail))

  test "full when used == N":
    let head = initRawN[4](0).validate()
    let tail = initRawN[4](4).validate()  # 4 items = full
    check(fullN(head, tail))
    check(not emptyN(head, tail))

  test "usedN calculates correctly":
    let head = initRawN[4](2).validate()
    let tail = initRawN[4](5).validate()
    check(usedN(head, tail) == 3)

  test "usedN handles wrap":
    let head = initRawN[4](6).validate()
    let tail = initRawN[4](1).validate()  # Wrapped
    check(usedN(head, tail) == 3)  # 8 - 6 + 1 = 3? No: (1 - 6 + 8) = 3

  test "availableN calculates correctly":
    let head = initRawN[4](0).validate()
    let tail = initRawN[4](2).validate()
    check(availableN(head, tail) == 2)

suite "N+1-slot fullness (for SPSC)":

  test "empty when head == tail":
    let head = initRawN1[4](0).validate()
    let tail = initRawN1[4](0).validate()
    check(emptyN1(head, tail))

  test "full when used == N":
    let head = initRawN1[4](0).validate()
    let tail = initRawN1[4](4).validate()
    check(fullN1(head, tail))

  test "usedN1 calculates correctly":
    let head = initRawN1[4](2).validate()
    let tail = initRawN1[4](5).validate()
    check(usedN1(head, tail) == 3)
