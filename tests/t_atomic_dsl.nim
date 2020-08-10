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
    atom.relaxed(2)
    assert(atom.acquire == 2)
