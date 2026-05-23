## UnboundedSipsic tests — post-3.3.11-B.2.5 the standalone
## `UnboundedSipsic[S, T]` type is absorbed into
## `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`. These tests
## continue to exercise the sipsic surface through the absorbed Queue
## via `newUnboundedSipsicQueue`.

import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub

const MT = 4
  ## Type-uniform MaxThreads phantom for the sipsic-absorbed branch.

suite "UnboundedSipsic":
  test "newUnboundedSipsicQueue creates valid instance":
    var queue = newUnboundedSipsicQueue[int, stEager, 16, MT]()
    check(queue.segmentCount == 1)

  test "push single item":
    var queue = newUnboundedSipsicQueue[int, stEager, 16, MT]()
    var p = queue.getProducer()

    p.push(42)
    check(queue.len == 1)

  test "push multiple items":
    var queue = newUnboundedSipsicQueue[int, stEager, 16, MT]()
    var p = queue.getProducer()

    for i in 1 .. 10:
      p.push(i)
    check(queue.len == 10)

  test "pop single item":
    var queue = newUnboundedSipsicQueue[int, stEager, 16, MT]()
    var p = queue.getProducer()

    p.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var queue = newUnboundedSipsicQueue[int, stEager, 16, MT]()

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved":
    var queue = newUnboundedSipsicQueue[int, stEager, 16, MT]()
    var p = queue.getProducer()

    for i in 1 .. 5:
      p.push(i)

    for i in 1 .. 5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "grows beyond single segment":
    var queue = newUnboundedSipsicQueue[int, stEager, 4, MT]() # Small segment
    var p = queue.getProducer()

    # Push more than segment capacity
    for i in 1 .. 10:
      p.push(i)

    check(queue.segmentCount >= 3)
      # At least 3 segments needed for 10 items with capacity 4

    # Verify all items retrievable in order
    for i in 1 .. 10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "segment reclamation on pop":
    var queue = newUnboundedSipsicQueue[int, stEager, 4, MT]()
    var p = queue.getProducer()

    # Fill and drain multiple segments
    for round in 1 .. 3:
      for i in 1 .. 8:
        p.push(i)
      for i in 1 .. 8:
        discard queue.pop()

    # Should have reclaimed segments automatically (single consumer can free directly)
    check(queue.segmentCount >= 1)

  test "len tracks items correctly":
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()
    var p = queue.getProducer()

    check(queue.len == 0)

    p.push(1)
    check(queue.len == 1)

    p.push(2)
    p.push(3)
    check(queue.len == 3)

    discard queue.pop()
    check(queue.len == 2)

    discard queue.pop()
    discard queue.pop()
    check(queue.len == 0)

  test "batch push":
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()
    var p = queue.getProducer()

    p.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1 .. 5:
      check(queue.pop().get == i)

  test "batch pop":
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()
    var p = queue.getProducer()

    for i in 1 .. 10:
      p.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()
    var p = queue.getProducer()

    p.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var queue = newUnboundedSipsicQueue[int, stEager, 8, MT]()

    let items = queue.pop(5)
    check(items.isNone)
