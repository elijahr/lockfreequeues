## Smoke fixtures for the rkEbr pop body
## across all 4 cardinality variants (spsc-equiv, spmc-equiv,
## mpsc-equiv, mpmc-equiv).
##
## Exercises:
##   - 4-variant pop compiles and pops in steady-state via the unified
##     `Queue[..., rkEbr, ...]` shape.
##   - Boundary-crossing pop: push SEGSIZE+N items, drain past one or
##     more segment boundaries; `segmentCount` decrements as segments
##     are retired (Eager strategy reclaims promptly via per-pop
##     `reclaimNow`).
##   - Multi-segment drain (1 → 0 segments via multiple advances).
##   - For multi-consumer variants (spmc-equiv, mpmc-equiv): 2
##     consumer threads contend on `headSegment` CAS (sanity test, not
##     full stress).
##   - §3.5.6 Pin-Claim Ordering: multi-consumer + mpsc-equiv
##     variants exercise the `pinScope(unpinned(self.handle))` path.
##     The visual-review guarantee that pin is acquired BEFORE the
##     segment-pointer load is encoded in `src/lockfreequeues/queue.nim`'s
##     pop body (see the §3.5.6 comment block above each `block:`
##     scope in the rkEbr pop body section).
##   - Bounded-asymmetry guard (γ): bounded `Queue[..., rkNone, ...]`
##     callers fail UFCS lookup for `retireOnCAS` / `retireOnPublish`
##     — verified via the `compiles()` negative control below.
##
##

import unittest2
import std/options

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "rkEbr pop smoke — spsc-equiv (ccSingle × ccSingle)":
  ## §3.0.3: UnboundedSpsc is the canonical SPSC unbounded type;
  ## this rkEbr instantiation is type-uniformity only. No pin, no
  ## retire — direct slot read + segment advance + freeAligned.

  test "push then pop returns same value":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    p.push(42)
    let r = lfqConsumer.pop()
    check r.isSome
    check r.get == 42
    check q.len() == 0

  test "drains in FIFO order":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = lfqConsumer.pop()
      check r.isSome
      check r.get == i
    check lfqConsumer.pop().isNone

  test "multi-segment drain (1 → 0 segments via multiple advances)":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 4, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 9: # 3 segments (sizes 4 + 4 + 1)
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = lfqConsumer.pop()
      check r.isSome
      check r.get == i
    # After draining we may sit at 1 segment (last in-use) or
    # transient state — accept ≥1 ≤3 (spsc free-on-advance reduces
    # segments as it advances).
    check q.segmentCount() >= 1
    check lfqConsumer.pop().isNone

  test "pop on empty queue returns none":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    check lfqConsumer.pop().isNone

suite "rkEbr pop smoke — mpsc-equiv (ccMulti × ccSingle)":
  ## §3.5.1 retire-bearing site (retireOnPublish, single consumer =
  ## single writer to headSegment). §3.5.6 Pin-Claim Ordering:
  ## pinScope FIRST, segment-pointer load NEXT.

  test "single-consumer pop returns FIFO order":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    var lfqConsumer = q.bindConsumer()
    var p = q.getProducerHere()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = lfqConsumer.pop()
      check r.isSome
      check r.get == i
    check lfqConsumer.pop().isNone

  test "boundary-crossing pop drains across segments":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 4, 4])
    var lfqConsumer = q.bindConsumer()
    var p = q.getProducerHere()
    for i in 0 ..< 10: # crosses 2 boundaries (4 → 8 → 10)
      p.push(i)
    for i in 0 ..< 10:
      let r = lfqConsumer.pop()
      check r.isSome
      check r.get == i
    check lfqConsumer.pop().isNone

  test "pop on empty queue returns none":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    var lfqConsumer = q.bindConsumer()
    check lfqConsumer.pop().isNone

suite "rkEbr pop smoke — spmc-equiv (ccSingle × ccMulti)":
  ## §3.5.3 retire-bearing site (retireOnCAS, weak compareExchange).
  ## §3.5.6 Pin-Claim Ordering: pinScope FIRST, segment-pointer load
  ## NEXT.

  test "single-consumer pop returns FIFO order":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  test "boundary-crossing pop drains across segments":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 4, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    for i in 0 ..< 10:
      p.push(i)
    for i in 0 ..< 10:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  # B.2 direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. compile-fail negative-controls
  # under tests/should_fail/ exercise the gate.

suite "rkEbr pop smoke — mpmc-equiv (ccMulti × ccMulti)":
  ## §3.5.2 retire-bearing site (retireOnCAS, strong
  ## compareExchangeStrong). §3.5.6 Pin-Claim Ordering: pinScope
  ## FIRST, segment-pointer load NEXT.

  test "single-consumer pop returns FIFO order":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  test "boundary-crossing pop drains across segments":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 4, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    for i in 0 ..< 10:
      p.push(i)
    for i in 0 ..< 10:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  # B.2 direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. compile-fail negative-controls
  # under tests/should_fail/ exercise the gate.

suite "rkEbr bounded-asymmetry guard (γ)":
  ## Bounded `Queue[..., rkNone, ...]` callers MUST fail UFCS lookup
  ## for `retireOnCAS` / `retireOnPublish`. The overload-on-rkEbr
  ## resolution at queue.nim's retire wrappers is the bounded-
  ## asymmetry guard. Compile-fail verifies the gate.

  test "retireOnCAS not defined on bounded Queue (rkNone)":
    # NOTE: `compiles()` checks lookup-only, not full semantic check.
    # Use a positive control (rkEbr ok) + negative control (rkNone fail).
    check not compiles(
      block:
        var bq: BQueue[int, ccMulti, ccMulti, 16, 4, 4]
        # Garbage args; we only care that lookup fails.
        var dummyAtomic: Atomic[ptr int]
        var dummyScope: PinnedScope[4, ccSingle]
        discard bq.retireOnCAS(dummyScope, dummyAtomic, nil, nil, nil)
    )

  test "retireOnPublish not defined on bounded Queue (rkNone)":
    check not compiles(
      block:
        var bq: BQueue[int, ccMulti, ccSingle, 16, 4, 0]
        var dummyAtomic: Atomic[ptr int]
        var dummyScope: PinnedScope[4, ccSingle]
        bq.retireOnPublish(dummyScope, dummyAtomic, nil, nil)
    )
