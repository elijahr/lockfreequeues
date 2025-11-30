# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import unittest2

import lockfreequeues/epoch


suite "EpochManager":

  test "newEpochManager creates valid instance":
    let manager = newEpochManager()
    check(manager != nil)
    check(manager.globalEpoch.load(moRelaxed) == 1)

  test "registerThread returns unique indices":
    let manager = newEpochManager()
    let idx1 = manager.registerThread()
    let idx2 = manager.registerThread()
    check(idx1 == 0)
    check(idx2 == 1)
    check(idx1 != idx2)

  test "pin sets thread epoch to global epoch":
    let manager = newEpochManager()
    let idx = manager.registerThread()

    check(manager.threadStates[idx].load(moRelaxed) == 0)  # unpinned

    let guard = manager.pin(idx)
    check(manager.threadStates[idx].load(moRelaxed) == 1)  # pinned to epoch 1

  test "unpin clears thread epoch":
    let manager = newEpochManager()
    let idx = manager.registerThread()

    block:
      let guard = manager.pin(idx)
      check(manager.threadStates[idx].load(moRelaxed) == 1)
    # guard destroyed here

    check(manager.threadStates[idx].load(moRelaxed) == 0)  # unpinned

  test "advance increments global epoch":
    let manager = newEpochManager()
    check(manager.globalEpoch.load(moRelaxed) == 1)

    manager.advance()
    check(manager.globalEpoch.load(moRelaxed) == 2)

    manager.advance()
    check(manager.globalEpoch.load(moRelaxed) == 3)

  test "retire adds to retire queue":
    let manager = newEpochManager()
    var dummy1: int = 42
    var dummy2: int = 99

    manager.retire(addr dummy1)
    check(manager.retireQueueLen == 1)

    manager.retire(addr dummy2)
    check(manager.retireQueueLen == 2)

  test "safeToReclaim when no threads pinned":
    let manager = newEpochManager()
    discard manager.registerThread()

    # No threads pinned, epoch 1 should be safe
    check(manager.safeToReclaim(1) == true)

  test "safeToReclaim false when thread pinned to epoch":
    let manager = newEpochManager()
    let idx = manager.registerThread()

    let guard = manager.pin(idx)

    # Thread pinned to epoch 1, so epoch 1 is not safe
    check(manager.safeToReclaim(1) == false)

    # Epoch 0 would be safe (older than pinned)
    # But we start at epoch 1, so this is edge case

  test "tryReclaim frees segments when safe":
    let manager = newEpochManager()
    let idx = manager.registerThread()

    # Allocate some memory
    var segment = cast[pointer](alloc(64))

    # Retire at epoch 1
    manager.retire(segment)
    check(manager.retireQueueLen == 1)

    # Advance epoch
    manager.advance()
    check(manager.globalEpoch.load(moRelaxed) == 2)

    # No threads pinned, reclaim should succeed
    let reclaimed = manager.tryReclaim()
    check(reclaimed == 1)
    check(manager.retireQueueLen == 0)

  test "tryReclaim preserves segments when threads pinned":
    let manager = newEpochManager()
    let idx = manager.registerThread()

    var segment = cast[pointer](alloc(64))

    # Pin before retiring
    let guard = manager.pin(idx)

    # Retire at epoch 1
    manager.retire(segment)
    check(manager.retireQueueLen == 1)

    # Advance epoch
    manager.advance()

    # Thread still pinned to epoch 1, cannot reclaim
    let reclaimed = manager.tryReclaim()
    check(reclaimed == 0)
    check(manager.retireQueueLen == 1)

    # Clean up manually since we didn't reclaim
    dealloc(segment)


suite "EpochGuard":

  test "destructor unpins automatically":
    let manager = newEpochManager()
    let idx = manager.registerThread()

    proc pinAndReturn(): int =
      let guard = manager.pin(idx)
      result = manager.threadStates[idx].load(moRelaxed).int

    let pinnedValue = pinAndReturn()
    check(pinnedValue == 1)

    # After proc returns, guard destroyed, should be unpinned
    check(manager.threadStates[idx].load(moRelaxed) == 0)
