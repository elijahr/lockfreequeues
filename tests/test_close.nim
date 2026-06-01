import std/unittest
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import lockfreequeues/bqueue
import lockfreequeues/queue

suite "close":
  test "Bound -> Closed transition (BQueue backend, no debra unregister)":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var u = Unbound[int, AnyThreadTag, typeof(q)](queue: addr q, idx: 0)
    var b = move(u).bindToThread()
    let c = move(b).close()
    check c.handleManager == nil
    check c.handleIdx == 0

  test "Bound -> Closed transition (Queue/MPSC backend, debra register/unregister)":
    # MPSC Queue is debra-integrated (ccProd=ccMulti). bindToThread should
    # call registerThread; close should call unregisterThread.
    var q = newUnboundedMpscQueue[int, stEager, 16, 4]()
    var u = Unbound[int, AnyThreadTag, typeof(q)](queue: addr q, idx: 0)
    var b = move(u).bindToThread()
    check b.handleManager != nil # Queue/MPSC: debra registration ran
    let c = move(b).close()
    # Closed carries the same handle the Queue unregister overload
    # consumed; the field stays populated post-close as a record.
    check c.handleManager != nil

  test "Bound -> Closed transition (Queue/SPSC backend, debra-free)":
    # SPSC Queue is debra-free per queue.nim:280-285 (absorbed UnboundedSpsc
    # body). bindToThread / close are no-ops via the `when compiles` gate.
    var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
    var u = Unbound[int, AnyThreadTag, typeof(q)](queue: addr q, idx: 0)
    var b = move(u).bindToThread()
    check b.handleManager == nil # SPSC Queue: no registration
    let c = move(b).close()
    check c.handleManager == nil
