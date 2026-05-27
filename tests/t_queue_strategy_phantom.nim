## Positive monomorphization test for the Strategy (`ST`) phantom on
## the unified Queue's rkEbr branch.
##
## Asserts that both `stManual` and `stEager` compile across the three
## multi-segment cardinality variants — mpsc-equiv, spmc-equiv,
## mpmc-equiv — and that the segment-count semantics differ between
## the two strategies:
##
## * `stEager` — the rkEbr pop body decrements `self.segments` after
##   each segment retire (the `when ST != stManual:` guard at the
##   retire site in `queue.nim`) and additionally calls
##   `reclaimNow(self.handle)` to actually free the retired segments.
##   Observable: `segmentCount()` decreases after drain.
## * `stManual` — the same guard suppresses the `segments` decrement
##   AND skips the `reclaimNow` tail call. Observable: `segmentCount()`
##   stays elevated after drain.
##
## Each test pushes 9 items into a queue with segment size S = 4 so the
## body spans 3 segments (4 + 4 + 1), drains all 9 items, then asserts
## the segment-count delta matches the strategy.
##
## lists this file by name; the assertion inventory is
## explicit at §6.3 (positive phantom). Earlier draft
## lockfreequeues v5.0.0 implementation.

import std/options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

import debra as debra_mod
from debra import initDebraManager, registerThread

suite "Strategy phantom — mpsc-equiv (ccMulti × ccSingle)":
  test "stManual: drained segments are retained (segmentCount stays at 3)":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var q = newUnboundedMpscQueue[int, stManual, 4, 4](addr manager, consumerHandle)
    var p = q.getProducer()
    p.attach()
    for i in 0 ..< 9:
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = q.pop()
      check r.isSome
      check r.get == i
    # stManual: segments counter is NOT decremented at retire sites.
    check q.segmentCount() == 3
    check q.pop().isNone

  test "stEager: drained segments are reclaimed (segmentCount decreases)":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var q = newUnboundedMpscQueue[int, stEager, 4, 4](addr manager, consumerHandle)
    var p = q.getProducer()
    p.attach()
    for i in 0 ..< 9:
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = q.pop()
      check r.isSome
      check r.get == i
    # stEager: segments counter decremented after each retire; final
    # count must be strictly less than the 3 we pushed across.
    check q.segmentCount() < 3
    check q.pop().isNone

suite "Strategy phantom — spmc-equiv (ccSingle × ccMulti)":
  test "stManual: drained segments are retained (segmentCount stays at 3)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedSpmcQueue[int, stManual, 4, 4](addr manager)
    var p = q.getProducer()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 9:
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check q.segmentCount() == 3
    check c.pop().isNone

  test "stEager: drained segments are reclaimed (segmentCount decreases)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedSpmcQueue[int, stEager, 4, 4](addr manager)
    var p = q.getProducer()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 9:
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check q.segmentCount() < 3
    check c.pop().isNone

suite "Strategy phantom — mpmc-equiv (ccMulti × ccMulti)":
  test "stManual: drained segments are retained (segmentCount stays at 3)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[int, stManual, 4, 4](addr manager)
    var p = q.getProducer()
    p.attach()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 9:
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check q.segmentCount() == 3
    check c.pop().isNone

  test "stEager: drained segments are reclaimed (segmentCount decreases)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[int, stEager, 4, 4](addr manager)
    var p = q.getProducer()
    p.attach()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 9:
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check q.segmentCount() < 3
    check c.pop().isNone
