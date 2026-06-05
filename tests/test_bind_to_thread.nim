import std/unittest
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import lockfreequeues/bqueue

suite "bindToThread":
  test "Unbound -> Bound transition (BQueue backend, no debra)":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var u = Unbound[int, AnyThreadTag, typeof(q)](queue: addr q, idx: 0)
    let b = move(u).bindToThread()
    when defined(debug):
      check b.attachedTid != 0
    check b.idx == 0
    check b.handleManager == nil # BQueue: no debra registration
