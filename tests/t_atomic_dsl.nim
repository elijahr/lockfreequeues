import debra/atomics
import debra/atomics/dsl
import unittest2

import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "atomic_dsl":
  var atom: Atomic[int]

  test "integration":
    atom.relaxed(1)
    assert(atom.relaxed == 1)
    atom.relaxed(2)
    assert(atom.acquire == 2)
