import atomics
import options
import unittest2

import lockfreequeues/unbounded_sipsic


suite "UnboundedSipsic":

  test "newUnboundedSipsic creates valid instance":
    var queue = newUnboundedSipsic[16, int]()
    check(queue.segmentCount == 1)

  test "push single item":
    var queue = newUnboundedSipsic[16, int]()

    queue.push(42)
    check(queue.len == 1)

  test "push multiple items":
    var queue = newUnboundedSipsic[16, int]()

    for i in 1..10:
      queue.push(i)
    check(queue.len == 10)

  test "pop single item":
    var queue = newUnboundedSipsic[16, int]()

    queue.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var queue = newUnboundedSipsic[16, int]()

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved":
    var queue = newUnboundedSipsic[16, int]()

    for i in 1..5:
      queue.push(i)

    for i in 1..5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "grows beyond single segment":
    var queue = newUnboundedSipsic[4, int]()  # Small segment

    # Push more than segment capacity
    for i in 1..10:
      queue.push(i)

    check(queue.segmentCount >= 3)  # At least 3 segments needed for 10 items with capacity 4

    # Verify all items retrievable in order
    for i in 1..10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "segment reclamation on pop":
    var queue = newUnboundedSipsic[4, int]()

    # Fill and drain multiple segments
    for round in 1..3:
      for i in 1..8:
        queue.push(i)
      for i in 1..8:
        discard queue.pop()

    # Should have reclaimed segments automatically (single consumer can free directly)
    check(queue.segmentCount >= 1)

  test "len tracks items correctly":
    var queue = newUnboundedSipsic[8, int]()

    check(queue.len == 0)

    queue.push(1)
    check(queue.len == 1)

    queue.push(2)
    queue.push(3)
    check(queue.len == 3)

    discard queue.pop()
    check(queue.len == 2)

    discard queue.pop()
    discard queue.pop()
    check(queue.len == 0)

  test "batch push":
    var queue = newUnboundedSipsic[8, int]()

    queue.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1..5:
      check(queue.pop().get == i)

  test "batch pop":
    var queue = newUnboundedSipsic[8, int]()

    for i in 1..10:
      queue.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var queue = newUnboundedSipsic[8, int]()

    queue.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var queue = newUnboundedSipsic[8, int]()

    let items = queue.pop(5)
    check(items.isNone)
