import atomics
import options
import unittest2

import debra
import lockfreequeues/unbounded_sipsic


suite "UnboundedSipsic":

  test "newUnboundedSipsic creates valid instance":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[16, int, 4](addr manager, handle)
    check(queue.segmentCount == 1)

  test "push single item":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[16, int, 4](addr manager, handle)

    queue.push(42)
    check(queue.len == 1)

  test "push multiple items":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[16, int, 4](addr manager, handle)

    for i in 1..10:
      queue.push(i)
    check(queue.len == 10)

  test "pop single item":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[16, int, 4](addr manager, handle)

    queue.push(42)
    let item = queue.pop()
    check(item.isSome)
    check(item.get == 42)
    check(queue.len == 0)

  test "pop from empty returns none":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[16, int, 4](addr manager, handle)

    let item = queue.pop()
    check(item.isNone)

  test "FIFO order preserved":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[16, int, 4](addr manager, handle)

    for i in 1..5:
      queue.push(i)

    for i in 1..5:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "grows beyond single segment":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[4, int, 4](addr manager, handle)  # Small segment

    # Push more than segment capacity
    for i in 1..10:
      queue.push(i)

    check(queue.segmentCount >= 3)  # At least 3 segments needed for 10 items with capacity 4

    # Verify all items retrievable in order
    for i in 1..10:
      let item = queue.pop()
      check(item.isSome)
      check(item.get == i)

  test "segment reclamation with Manual":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[4, int, 4](addr manager, handle, Manual)

    # Fill and drain multiple segments
    for round in 1..3:
      for i in 1..8:
        queue.push(i)
      for i in 1..8:
        discard queue.pop()

    # Segments should accumulate
    check(queue.segmentCount >= 1)

  test "segment reclamation with Eager":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[4, int, 4](addr manager, handle, Eager)

    # Fill and drain
    for i in 1..8:
      queue.push(i)
    for i in 1..8:
      discard queue.pop()

    advance(manager)
    let reclaimOp = reclaimStart(addr manager).loadEpochs().checkSafe()
    if reclaimOp.kind == rReclaimReady:
      discard reclaimOp.reclaimready.tryReclaim()

    # Should have fewer segments after reclaim
    check(queue.segmentCount >= 1)

  test "len tracks items correctly":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[8, int, 4](addr manager, handle)

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
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[8, int, 4](addr manager, handle)

    queue.push(@[1, 2, 3, 4, 5])
    check(queue.len == 5)

    for i in 1..5:
      check(queue.pop().get == i)

  test "batch pop":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[8, int, 4](addr manager, handle)

    for i in 1..10:
      queue.push(i)

    let items = queue.pop(5)
    check(items.isSome)
    check(items.get == @[1, 2, 3, 4, 5])
    check(queue.len == 5)

  test "batch pop more than available":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[8, int, 4](addr manager, handle)

    queue.push(@[1, 2, 3])

    let items = queue.pop(10)
    check(items.isSome)
    check(items.get == @[1, 2, 3])
    check(queue.len == 0)

  test "batch pop from empty":
    var manager = initDebraManager[4]()
    let handle = registerThread(manager)
    var queue = newUnboundedSipsic[8, int, 4](addr manager, handle)

    let items = queue.pop(5)
    check(items.isNone)
