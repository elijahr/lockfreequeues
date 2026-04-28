import unittest2
import lockfreequeues/typestates/virtual_values_n
import lockfreequeues/typestates/storage_n

suite "StorageN[N, T]":
  test "init sets all slots to default":
    var s: StorageN[4, int]
    s.init()
    # We need a valid slot to read
    let slot = initRawN[4](0).validate().index()
    check(s[slot] == 0)

  test "write and read via PhysicalSlotN":
    var s: StorageN[4, int]
    s.init()
    let slot = initRawN[4](2).validate().index()
    s[slot] = 42
    check(s[slot] == 42)

  test "all N slots accessible":
    var s: StorageN[4, string]
    s.init()
    for i in 0 ..< 4:
      let slot = initRawN[4](i).validate().index()
      s[slot] = "slot" & $i
    for i in 0 ..< 4:
      let slot = initRawN[4](i).validate().index()
      check(s[slot] == "slot" & $i)
