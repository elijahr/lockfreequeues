# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

import atomics
import unittest

import lockfreequeues


suite "atomic_dsl":
  var atom: Atomic[int]

  test "integration":
    atom.relaxed(1)
    assert(atom.relaxed == 1)
    atom.consume(2)
    assert(atom.consume == 2)
    atom.acquire(3)
    assert(atom.acquire == 3)
    atom.release(5)
    assert(atom.release == 5)
    atom.acquireRelease(6)
    assert(atom.acquireRelease == 6)
    atom.sequential(7)
    assert(atom.sequential == 7)
    var expected = 10000
    var spins = 0
    while not atom.compareExchangeWeakReleaseRelaxed(expected, 8):
      check(expected == 7)
      inc spins
    check(spins == 1)

# let encountered = spinExchange 100 with 20 into trivial

# assert(encountered == 10)

# assert(trivial.sequential == 20)
