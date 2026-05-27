import unittest2
import ../adapters/lockfreequeues_mpmc_adapter
import ../adapter

suite "MpmcAdapter":
  test "push and pop":
    var q = initMpmcAdapter[16, int]()
    defer: q.deinitMpmcAdapter()
    check q.push(42) == prSuccess
    let popResult = q.pop()
    check popResult.success
    check popResult.value == 42

  test "empty pop":
    var q = initMpmcAdapter[16, int]()
    defer: q.deinitMpmcAdapter()
    let popResult = q.pop()
    check not popResult.success

  test "full queue":
    var q = initMpmcAdapter[4, int]()
    defer: q.deinitMpmcAdapter()
    check q.push(1) == prSuccess
    check q.push(2) == prSuccess
    check q.push(3) == prSuccess
    check q.push(4) == prSuccess
    # Queue is now full (4 items in capacity-4 queue)
    check q.push(5) == prFull

  test "name":
    var q = initMpmcAdapter[16, int]()
    defer: q.deinitMpmcAdapter()
    check q.name == "lockfreequeues/Mpmc[16]"
