import std/unittest
import lockfreequeues/endpoint
import lockfreequeues/role_tags

type DummyQueue = object

suite "bindToThread":
  test "Unbound -> Bound transition compiles and runs":
    var u = Unbound[int, AnyThreadTag, DummyQueue](queue: nil, idx: 0)
    let b = move(u).bindToThread()
    when defined(debug):
      check b.attachedTid != 0
    check b.idx == 0
