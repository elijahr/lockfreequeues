# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# tests/t_committed_flags_n.nim
import unittest2
import lockfreequeues/typestates/virtual_values_n
import lockfreequeues/typestates/committed_flags_n

suite "CommittedFlagsN[N]":

  test "init sets all flags to false":
    var c: CommittedFlagsN[4]
    c.init()
    let slot = initRawN[4](0).validate().index()
    check(c.load(slot) == false)

  test "store and load":
    var c: CommittedFlagsN[4]
    c.init()
    let slot = initRawN[4](2).validate().index()
    c.store(slot, true)
    check(c.load(slot) == true)

  test "independent slots":
    var c: CommittedFlagsN[4]
    c.init()
    let slot0 = initRawN[4](0).validate().index()
    let slot1 = initRawN[4](1).validate().index()
    c.store(slot0, true)
    check(c.load(slot0) == true)
    check(c.load(slot1) == false)
