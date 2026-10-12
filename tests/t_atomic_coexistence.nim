import unittest2
import std/atomics
import options
import lockfreequeues
import lockfreequeues/sipsic
import lockfreequeues/mupsic

suite "Atomic coexistence with std/atomics":
  test "std/atomics Atomic and lockfreequeues do not collide":
    var a: Atomic[int]
    a.store(42)
    check a.load == 42

    var q = initSipsic[16, int]()
    check q.push(100)
    let val = q.pop()
    check val.isSome and val.get == 100
