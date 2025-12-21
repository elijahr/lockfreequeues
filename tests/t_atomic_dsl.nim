import atomics
import unittest2

import lockfreequeues

suite "atomic_dsl":
  var atom: Atomic[int]

  test "integration":
    atom.relaxed(1)
    assert(atom.relaxed == 1)
    atom.relaxed(2)
    assert(atom.acquire == 2)
