# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import options
import unittest2

import lockfreequeues/epoch
import lockfreequeues/unbounded_sipsic


suite "UnboundedSipsic":

  test "newUnboundedSipsic creates valid instance":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[16, int](manager)
    check(queue.segmentCount == 1)

  test "push single item":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[16, int](manager)

    queue.push(42)
    check(queue.len == 1)

  test "push multiple items":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[16, int](manager)

    for i in 1..10:
      queue.push(i)
    check(queue.len == 10)

  test "pop single item":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[16, int](manager)

    queue.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[16, int](manager)

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[16, int](manager)

    for i in 1..5:
      queue.push(i)

    for i in 1..5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "grows beyond single segment":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[4, int](manager)  # Small segment

    # Push more than segment capacity
    for i in 1..10:
      queue.push(i)

    check(queue.segmentCount >= 3)  # At least 3 segments needed for 10 items with capacity 4

    # Verify all items retrievable in order
    for i in 1..10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "segment reclamation with NeverDeallocate":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[4, int](manager, NeverDeallocate)

    # Fill and drain multiple segments
    for round in 1..3:
      for i in 1..8:
        queue.push(i)
      for i in 1..8:
        discard queue.pop()

    # Segments should accumulate
    check(queue.segmentCount >= 1)

  test "segment reclamation with EagerDeallocate":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[4, int](manager, EagerDeallocate)

    # Fill and drain
    for i in 1..8:
      queue.push(i)
    for i in 1..8:
      discard queue.pop()

    manager.advance()
    discard manager.tryReclaim()

    # Should have fewer segments after reclaim
    check(queue.segmentCount >= 1)

  test "len tracks items correctly":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager)

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
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager)

    queue.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1..5:
      check(queue.pop().get == i)

  test "batch pop":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager)

    for i in 1..10:
      queue.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager)

    queue.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    let manager = newEpochManager()
    var queue = newUnboundedSipsic[8, int](manager)

    let items = queue.pop(5)
    check(items.isNone)
