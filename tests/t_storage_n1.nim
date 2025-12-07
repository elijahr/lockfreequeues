import unittest2
import lockfreequeues/typestates/virtual_values_n1
import lockfreequeues/typestates/storage_n1

suite "StorageN1[N, T]":

  test "init sets all N+1 slots to default":
    var s: StorageN1[4, int]
    s.init()
    let slot = initRawN1[4](0).validate().index()
    check(s[slot] == 0)

  test "write and read via PhysicalSlotN1":
    var s: StorageN1[4, int]
    s.init()
    let slot = initRawN1[4](2).validate().index()
    s[slot] = 42
    check(s[slot] == 42)

  test "all N+1 slots accessible":
    var s: StorageN1[4, string]
    s.init()
    # N+1 = 5 slots for N=4
    for i in 0..4:
      let slot = initRawN1[4](i).validate().index()
      s[slot] = "slot" & $i
    for i in 0..4:
      let slot = initRawN1[4](i).validate().index()
      check(s[slot] == "slot" & $i)
