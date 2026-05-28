## Smoke fixtures for the v5.0.0 smart-constructor surface
## (4 bounded + 4 unbounded). Each smart-constructor is exercised with
## a single construct + push/pop round-trip; the deeper push/pop
## behaviour is already pinned by the sibling smoke gates
## (`t_queue_bounded_*.nim`, `t_queue_unbounded_push_smoke.nim`,
## `t_queue_unbounded_pop_smoke.nim`) and the §3.0.2.4 soundness gates.
##
## the standalone `UnboundedSpsc[S, T]` was absorbed
## into `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]` and now
## ships its own smart constructor (`newUnboundedSpscQueue`) exercised below.
##
## **Push-uniform / pop-asymmetric**: `push` always goes through
## `QueueProducer.push` for `ccProd == ccMulti` and through
## `Queue.push` for `ccProd == ccSingle`; `pop` goes through
## `Queue.pop` for `ccCons == ccSingle` and through
## `QueueConsumer.pop` (via `getConsumer`) for `ccCons == ccMulti`.
##
## 

import std/options
import unittest2

import lockfreequeues/bqueue
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

# nim-debra surface for the manager-borrow smart-constructor tests.
# Selective `from ... import` matches the queue.nim convention and
# keeps `debra.ccSingle` / `debra.ccMulti` qualified-only, avoiding the
# unqualified `PinScopeCardinality` collision with the stub.
from debra import DebraManager, initDebraManager, registerThread

suite "bounded smart-constructors (RK = rkNone)":
  test "newSpscQueue: construct + push/pop round-trip":
    var q = newSpscQueue[int, 8]()
    check q.capacity == 8
    check q.push(42)
    let r = q.pop()
    check r.isSome
    check r.get == 42

  test "newMpscQueue: construct + push (via producer) + pop":
    var q = newMpscQueue[int, 16, 4]()
    check q.capacity == 16
    var p = q.getProducer(0)
    check p.push(7)
    let r = q.pop()
    check r.isSome
    check r.get == 7

  test "newSpmcQueue: construct + push + pop (via consumer)":
    var q = newSpmcQueue[int, 16, 4]()
    check q.capacity == 16
    check q.push(99)
    var c = q.getConsumer(0)
    let r = c.pop()
    check r.isSome
    check r.get == 99

  test "newMpmcQueue: construct + push (producer) + pop (consumer)":
    var q = newMpmcQueue[int, 16, 4, 4]()
    check q.capacity == 16
    var p = q.getProducer(0)
    check p.push(123)
    var c = q.getConsumer(0)
    let r = c.pop()
    check r.isSome
    check r.get == 123

suite "unbounded smart-constructors — newUnboundedSpscQueue":
  ## Spsc-absorbed branch: no debra, no manager. Only an auto-create
  ## overload is supported (manager-borrow is `{.error.}`-gated since
  ## spsc has no debra integration).
  test "auto-create: construct + push + pop":
    var q = newUnboundedSpscQueue[int, stEager, 8, 4]()
    var p = q.getProducer()
    p.push(10)
    p.push(20)
    let r1 = q.pop()
    let r2 = q.pop()
    check r1.isSome and r1.get == 10
    check r2.isSome and r2.get == 20
    check q.pop().isNone

suite "unbounded smart-constructors — newUnboundedMpscQueue":
  test "auto-create: construct + push + pop":
    var q = newUnboundedMpscQueue[int, stEager, 8, 4]()
    q.attachConsumer()
    var p = q.getProducer()
    p.attach()
    p.push(1)
    p.push(2)
    let r1 = q.pop()
    let r2 = q.pop()
    check r1.isSome and r1.get == 1
    check r2.isSome and r2.get == 2
    check q.pop().isNone

  test "borrow: construct + push + pop (manager owned externally)":
    var mgr = initDebraManager[4, debra.ccSingle]()
    let consumerHandle = registerThread(mgr)
    block:
      var q = newUnboundedMpscQueue[int, stEager, 8, 4](addr mgr, consumerHandle)
      var p = q.getProducer()
      p.attach()
      p.push(11)
      let r = q.pop()
      check r.isSome and r.get == 11
      check q.pop().isNone
    # q goes out of scope here; `=destroy` runs `unbindClient` but leaves
    # `mgr` intact (ownsManager = false). `mgr` is dropped by Nim's
    # default destructor at suite-test scope exit.

suite "unbounded smart-constructors — newUnboundedSpmcQueue":
  test "auto-create: construct + push + pop":
    var q = newUnboundedSpmcQueue[int, stEager, 8, 4]()
    var p = q.getProducer()
    p.push(3)
    p.push(4)
    var c = q.getConsumer()
    c.attach()
    let r1 = c.pop()
    let r2 = c.pop()
    check r1.isSome and r1.get == 3
    check r2.isSome and r2.get == 4
    check c.pop().isNone

  test "borrow: construct + push + pop (manager owned externally)":
    var mgr = initDebraManager[4, debra.ccMulti]()
    block:
      var q = newUnboundedSpmcQueue[int, stEager, 8, 4](addr mgr)
      var p = q.getProducer()
      p.push(22)
      var c = q.getConsumer()
      c.attach()
      let r = c.pop()
      check r.isSome and r.get == 22
      check c.pop().isNone

suite "unbounded smart-constructors — newUnboundedMpmcQueue":
  test "auto-create: construct + push + pop":
    var q = newUnboundedMpmcQueue[int, stEager, 8, 4]()
    var p = q.getProducer()
    p.attach()
    p.push(5)
    p.push(6)
    var c = q.getConsumer()
    c.attach()
    let r1 = c.pop()
    let r2 = c.pop()
    check r1.isSome and r1.get == 5
    check r2.isSome and r2.get == 6
    check c.pop().isNone

  test "borrow: construct + push + pop (manager owned externally)":
    var mgr = initDebraManager[4, debra.ccMulti]()
    block:
      var q = newUnboundedMpmcQueue[int, stEager, 8, 4](addr mgr)
      var p = q.getProducer()
      p.attach()
      p.push(33)
      var c = q.getConsumer()
      c.attach()
      let r = c.pop()
      check r.isSome and r.get == 33
      check c.pop().isNone

suite "smart-constructor =destroy soundness":
  ## Each auto-create overload claims `ownsManager = true`; the queue's
  ## `=destroy` must run the manager's destructor cleanly (which asserts
  ## `clientCount == 0` internally). If any client bookkeeping is
  ## mis-routed by the smart-constructors, manager destruction would
  ## crash here. Exiting the inner block cleanly is the test.

  test "newUnboundedMpscQueue auto-create destructor runs cleanly":
    block:
      var q = newUnboundedMpscQueue[int, stEager, 8, 4]()
      q.attachConsumer()
      var p = q.getProducer()
      p.attach()
      p.push(1)
      discard q.pop()
    check true # reached only if =destroy did not assert/crash

  test "newUnboundedSpmcQueue auto-create destructor runs cleanly":
    block:
      var q = newUnboundedSpmcQueue[int, stEager, 8, 4]()
      var p = q.getProducer()
      p.push(1)
      var c = q.getConsumer()
      c.attach()
      discard c.pop()
    check true

  test "newUnboundedMpmcQueue auto-create destructor runs cleanly":
    block:
      var q = newUnboundedMpmcQueue[int, stEager, 8, 4]()
      var p = q.getProducer()
      p.attach()
      p.push(1)
      var c = q.getConsumer()
      c.attach()
      discard c.pop()
    check true
