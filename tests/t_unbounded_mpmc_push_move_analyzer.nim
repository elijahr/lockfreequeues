## Task 19 (β3) — atomicArc move-analyzer baseline for unbounded MPMC.
##
## Characterization test: demonstrates the MPMC push/pop path can carry a
## genuinely non-copyable, sink-only `T` under `--mm:atomicArc --threads:on`,
## including the pendingItem-through-segment-escalation case.
##
## A type whose `=copy` is disabled (`{.error.}`) cannot be copied by the
## compiler. If the MPMC facade's push parameter, the typestate's
## `startPush` -> `tryClaimSlot` -> `writeItem` chain, or the
## `SegmentFull` / `SegmentClosed` escalation arms (which thread
## `pendingItem` through `tryAllocateNewSegment` and `closeSegmentDone`)
## ever required a copy at any step, this file would fail to COMPILE under
## atomicArc's move-analyzer with a clear "'=copy' is not available"
## error. A clean compile + passing pops therefore proves end-to-end
## move-only viability for both the steady-state and escalation paths.
##
## C-1 / C5 coverage (MPMC vs SPMC, see
## `src/lockfreequeues/typestates/unbounded_mpmc_push.nim:5-25`):
##   - NO entry `fetchAdd(seg.tail)` at the top of writeItem; the initial
##     slot comes from `claimed.slot` (set by the reservation CAS in
##     `tryClaimSlot`). The move-only `T` flows through `claimed`'s
##     `pendingItem` into the publish-CAS body.
##   - Shape A retry on publish-CAS failure uses
##     `seg.tail.fetchAdd(1, moRelaxed)` to obtain a fresh slot, NOT a
##     copy of `pendingItem`.
##   - Producer-vs-producer slot-claim CAS loss rebuilds `UMPMCPushReady`
##     and threads `pendingItem` forward (I-5 propagation, see facade at
##     `src/lockfreequeues/unbounded_mupmuc.nim:441-455`).
##   - Segment escalation (`UMPMCPushSegmentFull` ->
##     `tryAllocateNewSegment` -> fresh `UMPMCPushReady`) threads
##     `pendingItem` through every branch (see typestate at lines
##     333-395).
##
## Compile (the gate this test enforces):
##   nim c --mm:atomicArc --threads:on --path:src \
##     -r tests/t_unbounded_mpmc_push_move_analyzer.nim
##
## Expected: this test PASSES on first run with no source changes. A
## compile error mentioning copy/clone of `MovePayload` indicates a
## regression in the MPMC push/pop chain (a non-sink read introduced
## somewhere on the path) and should be surfaced to the orchestrator.

import options
import unittest2

import debra
import lockfreequeues/unbounded_mupmuc

type
  ## Move-only payload. `=copy` is disabled with `{.error.}`, the idiomatic
  ## Nim marker for a sink-only type. Any attempted copy by the compiler
  ## (parameter binding, RHS read, assignment from an lvalue, `seq` growth,
  ## etc.) becomes a hard compile error rather than a silent duplication.
  ##
  ## Carries a non-trivial body (an owned `seq[int]` plus a tag) so the
  ## post-pop assertion validates the FULL moved value, not just an
  ## inlined int that the compiler could trivially shuffle through a
  ## register without ever exercising `=sink` at all.
  ##
  ## CRITICAL-1: mirrors Task 11's SPMC analog (see
  ## `tests/t_unbounded_spmc_push_move_analyzer.nim`) so the two
  ## move-analyzer baselines diverge only on the queue facade under test.
  MovePayload = object
    tag: int
    payload: seq[int]

proc `=copy`(dst: var MovePayload, src: MovePayload) {.error.}
  ## Disable copy. If the MPMC push/pop chain ever needs to copy a
  ## `MovePayload`, the compiler will reject this file at the offending
  ## call site with "'=copy' is not available for type <MovePayload>".

proc makeMovePayload(tag: int, contents: openArray[int]): MovePayload =
  ## Sink-only constructor: builds a fresh `MovePayload` from a tag and
  ## an array of ints. Returned by value; the caller takes ownership via
  ## the move analyzer's NRVO / sink-result handling.
  result.tag = tag
  result.payload = newSeqOfCap[int](contents.len)
  for v in contents:
    result.payload.add(v)

suite "Task 19 LCRQ MPMC move-analyzer baseline (β3)":
  test "single push/pop carries a non-copyable MovePayload end-to-end":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, MovePayload, 4](addr manager)

    # Construct, then push. `item` is at its last use on the `push` line,
    # so under arc/atomicArc the move analyzer must turn the parameter
    # bind into a sink. If it cannot, this line fails to compile.
    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var item = makeMovePayload(7, [10, 20, 30])
    producer.push(item)
    check queue.len == 1

    let consumerHandle = registerThread(manager)
    var consumer = queue.getConsumer(consumerHandle)
    var popped = consumer.pop()

    # Full-assertion form: verify EVERY field of the popped MovePayload.
    # `popped` is `Option[MovePayload]`. Under atomicArc the move analyzer
    # cannot move out of `Option.get` (which returns `lent T`) into a fresh
    # local for a non-copyable `T`, so we read field-by-field directly off
    # the borrowed value via `popped.get`. Each `popped.get` call returns
    # a borrow; field reads on that borrow do not require `=copy`. Field
    # equality covers EVERY field of MovePayload (tag + payload), so a
    # corrupted/zeroed/scrambled value would fail at least one assertion.
    check popped.isSome
    check popped.get.tag == 7
    check popped.get.payload == @[10, 20, 30]
    check queue.len == 0

  test "two sequential pushes/pops preserve FIFO with non-copyable T":
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[16, MovePayload, 4](addr manager)

    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)
    var first = makeMovePayload(1, [100, 101])
    var second = makeMovePayload(2, [200, 201, 202])
    producer.push(first)
    producer.push(second)
    check queue.len == 2

    let consumerHandle = registerThread(manager)
    var consumer = queue.getConsumer(consumerHandle)

    var popped1 = consumer.pop()
    check popped1.isSome
    check popped1.get.tag == 1
    check popped1.get.payload == @[100, 101]

    var popped2 = consumer.pop()
    check popped2.isSome
    check popped2.get.tag == 2
    check popped2.get.payload == @[200, 201, 202]

    check queue.len == 0
    check consumer.pop().isNone

  test "pendingItem threads through MPMC SegmentFull escalation with non-copyable T":
    # Segment size S=2 forces a SegmentFull escalation on the third push:
    # the first two pushes fill the initial segment, and the third must
    # walk the typestate's UMPMCPushSegmentFull -> tryAllocateNewSegment
    # -> fresh UMPMCPushReady path. `pendingItem` is threaded through
    # every branch of that escalation (see typestate at
    # `src/lockfreequeues/typestates/unbounded_mpmc_push.nim:333-395`).
    # If any branch read `pendingItem` non-sink, the compile would fail
    # here on a non-copyable T. A clean compile + the FIFO assertion
    # below proves the move-only payload survived the rotation.
    var manager = initDebraManager[4]()
    var queue = newUnboundedMupmuc[2, MovePayload, 4](addr manager)

    let producerHandle = registerThread(manager)
    var producer = queue.getProducer(producerHandle)

    var a = makeMovePayload(10, [1, 2])
    var b = makeMovePayload(20, [3, 4, 5])
    var c = makeMovePayload(30, [6, 7, 8, 9])
    var d = makeMovePayload(40, [11])

    producer.push(a) # slot 0 of segment 1
    producer.push(b) # slot 1 of segment 1 (fills it)
    producer.push(c) # escalates: SegmentFull -> tryAllocateNewSegment -> slot 0 of segment 2
    producer.push(d) # slot 1 of segment 2
    check queue.len == 4

    let consumerHandle = registerThread(manager)
    var consumer = queue.getConsumer(consumerHandle)

    var popA = consumer.pop()
    check popA.isSome
    check popA.get.tag == 10
    check popA.get.payload == @[1, 2]

    var popB = consumer.pop()
    check popB.isSome
    check popB.get.tag == 20
    check popB.get.payload == @[3, 4, 5]

    # The next pop crosses the segment boundary; the moved-only payload
    # was carried through the producer's SegmentFull escalation.
    var popC = consumer.pop()
    check popC.isSome
    check popC.get.tag == 30
    check popC.get.payload == @[6, 7, 8, 9]

    var popD = consumer.pop()
    check popD.isSome
    check popD.get.tag == 40
    check popD.get.payload == @[11]

    check queue.len == 0
    check consumer.pop().isNone
