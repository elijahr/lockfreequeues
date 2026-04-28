## Test that UnboundedSipsic accepts lock-free types.

import std/options
import unittest2
import ../src/lockfreequeues/unbounded_sipsic

suite "UnboundedSipsic lock-free types":
  test "int is lock-free":
    var queue = newUnboundedSipsic[64, int]()
    queue.push(42)
    let item = queue.pop()
    check item.isSome
    check item.get == 42

  test "pointer is lock-free":
    type NodeObj = object
      value: int

    var queue = newUnboundedSipsic[64, ptr NodeObj]()

    let node = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    node.value = 99

    queue.push(node)
    let item = queue.pop()
    check item.isSome
    check item.get.value == 99

    dealloc(node)

  test "uint64 is lock-free":
    var queue = newUnboundedSipsic[64, uint64]()
    queue.push(0xDEADBEEF'u64)
    let item = queue.pop()
    check item.isSome
    check item.get == 0xDEADBEEF'u64
