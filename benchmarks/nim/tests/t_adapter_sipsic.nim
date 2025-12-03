# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest2
import ../adapters/lockfreequeues_sipsic
import ../adapter

suite "SipsicAdapter":
  test "push and pop":
    var q = initSipsicAdapter[16, int]()
    check q.push(42) == prSuccess
    let popResult = q.pop()
    check popResult.success
    check popResult.value == 42

  test "empty pop":
    var q = initSipsicAdapter[16, int]()
    let popResult = q.pop()
    check not popResult.success

  test "full queue":
    var q = initSipsicAdapter[4, int]()
    check q.push(1) == prSuccess
    check q.push(2) == prSuccess
    check q.push(3) == prSuccess
    check q.push(4) == prSuccess
    # Queue is now full (4 items in capacity-4 queue)
    check q.push(5) == prFull

  test "name":
    var q = initSipsicAdapter[16, int]()
    check q.name == "lockfreequeues/Sipsic[16]"
