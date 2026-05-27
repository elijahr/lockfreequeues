## Test that UnboundedSpsc accepts lock-free types.
##
## Post-3.3.11-B.2.5: the standalone `UnboundedSpsc[S, T]` is absorbed
## into `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`.

import std/options
import unittest2
import ../src/lockfreequeues/queue
import ../src/lockfreequeues/strategy
import ../src/lockfreequeues/internal/pinscope_stub

suite "UnboundedSpsc lock-free types":
  test "int is lock-free":
    var queue = newUnboundedSpscQueue[int, stEager, 64, 4]()
    var p = queue.getProducer()
    p.push(42)
    let item = queue.pop()
    check item.isSome
    check item.get == 42

  test "pointer is lock-free":
    type NodeObj = object
      value: int

    var queue = newUnboundedSpscQueue[ptr NodeObj, stEager, 64, 4]()
    var p = queue.getProducer()

    let node = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    node.value = 99

    p.push(node)
    let item = queue.pop()
    check item.isSome
    check item.get.value == 99

    dealloc(node)

  test "uint64 is lock-free":
    var queue = newUnboundedSpscQueue[uint64, stEager, 64, 4]()
    var p = queue.getProducer()
    p.push(0xDEADBEEF'u64)
    let item = queue.pop()
    check item.isSome
    check item.get == 0xDEADBEEF'u64
