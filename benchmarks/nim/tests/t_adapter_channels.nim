# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import unittest2
import ../adapters/channels_adapter
import ../adapter

suite "ChannelsAdapter":
  test "push and pop":
    var q = initChannelsAdapter[int](16)
    defer: q.deinitChannelsAdapter()
    check q.push(42) == prSuccess
    let popResult = q.pop()
    check popResult.success
    check popResult.value == 42

  test "empty pop":
    var q = initChannelsAdapter[int](16)
    defer: q.deinitChannelsAdapter()
    let popResult = q.pop()
    check not popResult.success

  test "full queue":
    var q = initChannelsAdapter[int](2)
    defer: q.deinitChannelsAdapter()
    check q.push(1) == prSuccess
    check q.push(2) == prSuccess
    check q.push(3) == prFull

  test "name":
    var q = initChannelsAdapter[int](16)
    defer: q.deinitChannelsAdapter()
    check q.name == "nim/channels"
