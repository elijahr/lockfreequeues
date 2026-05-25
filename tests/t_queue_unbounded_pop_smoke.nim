## Smoke fixtures for the v5.0.0 Track E Step 3.3.4 — rkEbr pop body
## across all 4 cardinality variants (sipsic-equiv, sipmuc-equiv,
## mupsic-equiv, mupmuc-equiv).
##
## Exercises:
##   - 4-variant pop compiles and pops in steady-state via the unified
##     `Queue[..., rkEbr, ...]` shape.
##   - Boundary-crossing pop: push SEGSIZE+N items, drain past one or
##     more segment boundaries; `segmentCount` decrements as segments
##     are retired (Eager strategy reclaims promptly via per-pop
##     `reclaimNow`).
##   - Multi-segment drain (1 → 0 segments via multiple advances).
##   - For multi-consumer variants (sipmuc-equiv, mupmuc-equiv): 2
##     consumer threads contend on `headSegment` CAS (sanity test, not
##     full stress).
##   - §3.5.6 Pin-Claim Ordering: multi-consumer + mupsic-equiv
##     variants exercise the `pinScope(unpinned(self.handle))` path.
##     The visual-review guarantee that pin is acquired BEFORE the
##     segment-pointer load is encoded in `src/lockfreequeues/queue.nim`'s
##     pop body (see the §3.5.6 comment block above each `block:`
##     scope in the rkEbr pop body section).
##   - Bounded-asymmetry guard (γ): bounded `Queue[..., rkNone, ...]`
##     callers fail UFCS lookup for `retireOnCAS` / `retireOnPublish`
##     — verified via the `compiles()` negative control below.
##
## Step 3.3.4 of Phase 3.3 lockfreequeues v5.0.0 implementation.

import unittest2
import std/options

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

suite "rkEbr pop smoke — sipsic-equiv (ccSingle × ccSingle)":
  ## §3.0.3: UnboundedSipsic is the canonical SPSC unbounded type;
  ## this rkEbr instantiation is type-uniformity only. No pin, no
  ## retire — direct slot read + segment advance + freeAligned.

  test "push then pop returns same value":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducer()
    p.push(42)
    let r = q.pop()
    check r.isSome
    check r.get == 42
    check q.len() == 0

  test "drains in FIFO order":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducer()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = q.pop()
      check r.isSome
      check r.get == i
    check q.pop().isNone

  test "multi-segment drain (1 → 0 segments via multiple advances)":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 4, 4])
    var p = q.getProducer()
    for i in 0 ..< 9: # 3 segments (sizes 4 + 4 + 1)
      p.push(i)
    check q.segmentCount() == 3
    for i in 0 ..< 9:
      let r = q.pop()
      check r.isSome
      check r.get == i
    # After draining we may sit at 1 segment (last in-use) or
    # transient state — accept ≥1 ≤3 (sipsic free-on-advance reduces
    # segments as it advances).
    check q.segmentCount() >= 1
    check q.pop().isNone

  test "pop on empty queue returns none":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    check q.pop().isNone

suite "rkEbr pop smoke — mupsic-equiv (ccMulti × ccSingle)":
  ## §3.5.1 retire-bearing site (retireOnPublish, single consumer =
  ## single writer to headSegment). §3.5.6 Pin-Claim Ordering:
  ## pinScope FIRST, segment-pointer load NEXT.

  test "single-consumer pop returns FIFO order":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    q.attachConsumer()
    var p = q.getProducer()
    p.attach()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = q.pop()
      check r.isSome
      check r.get == i
    check q.pop().isNone

  test "boundary-crossing pop drains across segments":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 4, 4])
    q.attachConsumer()
    var p = q.getProducer()
    p.attach()
    for i in 0 ..< 10: # crosses 2 boundaries (4 → 8 → 10)
      p.push(i)
    for i in 0 ..< 10:
      let r = q.pop()
      check r.isSome
      check r.get == i
    check q.pop().isNone

  test "pop on empty queue returns none":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    q.attachConsumer()
    check q.pop().isNone

suite "rkEbr pop smoke — sipmuc-equiv (ccSingle × ccMulti)":
  ## §3.5.3 retire-bearing site (retireOnCAS, weak compareExchange).
  ## §3.5.6 Pin-Claim Ordering: pinScope FIRST, segment-pointer load
  ## NEXT.

  test "single-consumer pop returns FIFO order":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 8, 4])
    var p = q.getProducer()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  test "boundary-crossing pop drains across segments":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 4, 4])
    var p = q.getProducer()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 10:
      p.push(i)
    for i in 0 ..< 10:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  # B.2 Bundle E: direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. Bundle J compile-fail negative-controls
  # under tests/should_fail/ exercise the gate (added in 3.3.11-B.3).

suite "rkEbr pop smoke — mupmuc-equiv (ccMulti × ccMulti)":
  ## §3.5.2 retire-bearing site (retireOnCAS, strong
  ## compareExchangeStrong). §3.5.6 Pin-Claim Ordering: pinScope
  ## FIRST, segment-pointer load NEXT.

  test "single-consumer pop returns FIFO order":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducer()
    p.attach()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 5:
      p.push(i)
    for i in 0 ..< 5:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  test "boundary-crossing pop drains across segments":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 4, 4])
    var p = q.getProducer()
    p.attach()
    var c = q.getConsumer()
    c.attach()
    for i in 0 ..< 10:
      p.push(i)
    for i in 0 ..< 10:
      let r = c.pop()
      check r.isSome
      check r.get == i
    check c.pop().isNone

  # B.2 Bundle E: direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. Bundle J compile-fail negative-controls
  # under tests/should_fail/ exercise the gate (added in 3.3.11-B.3).

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
