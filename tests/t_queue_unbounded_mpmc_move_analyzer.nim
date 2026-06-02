## Move-analyzer baseline for v5 unbounded MPMC `Queue` (cellState-stable port
## of v4.3-task-14 commit 510ef27).
##
## Characterization test: demonstrates that v5's MPMC unbounded push/pop chain
## can carry a genuinely non-copyable, sink-only `T` end-to-end, including
## the segment-escalation case (push spilling from one segment to the next
## via `tryAllocateNewSegment`).
##
## A type whose `=copy` is disabled (`{.error.}`) cannot be copied by the
## compiler. If v5's `push` parameter binding, the producer-side reservation
## CAS (`queue.nim:1003`) and committed-flag publication store
## (`queue.nim:1005`), or the segment-spill path (`queue.nim:newSegment` +
## `tailSegment.store`) ever required a copy at any step, this file would
## fail to COMPILE under atomicArc's move-analyzer with a clear
## "'=copy' is not available" error. A clean compile + passing pops therefore
## proves end-to-end move-only viability for both the steady-state and
## escalation paths.
##
## Compile (the gate this test enforces):
##   nim c --mm:atomicArc --threads:on --path:src \
##     -r tests/t_queue_unbounded_mpmc_move_analyzer.nim
##
## Expected: PASS on the v5 HEAD. A compile error mentioning copy/clone of
## `MovePayload` indicates a regression in v5's MPMC push/pop chain (a
## non-sink read introduced somewhere on the path).
##
## Origin: mirror of v4.3-task-14 commit 510ef27
## `tests/t_unbounded_mpmc_push_move_analyzer.nim`. The v4 facade
## (`unbounded_mupmuc.nim`) and typestate split (`unbounded_mpmc_push.nim`)
## don't exist in v5 — both are unified into `src/lockfreequeues/queue.nim`
## with cardinality-dispatched `when ccProd == ccMulti and ccCons == ccMulti`
## branches.

import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import lockfreequeues/strategy

type
  ## Move-only payload. `=copy` is disabled with `{.error.}`, the idiomatic
  ## Nim marker for a sink-only type. Any attempted copy by the compiler
  ## (parameter binding, RHS read, assignment from an lvalue, `seq` growth,
  ## etc.) becomes a hard compile error rather than a silent duplication.
  ##
  ## Carries a non-trivial body (an owned `seq[int]` plus a tag) so the
  ## post-pop assertion validates the FULL moved value, not just an inlined
  ## int that the compiler could trivially shuffle through a register
  ## without ever exercising `=sink` at all.
  MovePayload = object
    tag: int
    payload: seq[int]

proc `=copy`(dst: var MovePayload, src: MovePayload) {.error.}
  ## Disable copy. If v5's MPMC push/pop chain ever needs to copy a
  ## `MovePayload`, the compiler will reject this file at the offending
  ## call site with "'=copy' is not available for type <MovePayload>".

proc makeMovePayload(tag: int, contents: openArray[int]): MovePayload =
  ## Sink-only constructor: builds a fresh `MovePayload` from a tag and an
  ## array of ints. Returned by value; the caller takes ownership via the
  ## move analyzer's NRVO / sink-result handling.
  result.tag = tag
  result.payload = newSeqOfCap[int](contents.len)
  for v in contents:
    result.payload.add(v)

suite "v5 unbounded MPMC move-analyzer baseline":
  test "single push/pop carries a non-copyable MovePayload end-to-end":
    var q = newQueue(Queue[MovePayload, ccMulti, ccMulti, stEager, 16, 4])
    var producer = q.getProducerHere()
    var item = makeMovePayload(7, [10, 20, 30])
    producer.push(item)
    check q.len() == 1

    var consumer = q.getConsumerHere()
    var popped = consumer.pop()

    # Verify EVERY field of the popped MovePayload via borrow-reads off
    # `popped.get` (Option.get returns `lent T`; field reads on a borrow
    # do not require `=copy`). Field equality covers both fields, so a
    # corrupted/zeroed/scrambled value would fail at least one assertion.
    check popped.isSome
    check popped.get.tag == 7
    check popped.get.payload == @[10, 20, 30]
    check q.len() == 0

  test "two sequential pushes/pops preserve FIFO with non-copyable T":
    var q = newQueue(Queue[MovePayload, ccMulti, ccMulti, stEager, 16, 4])
    var producer = q.getProducerHere()
    var first = makeMovePayload(1, [100, 101])
    var second = makeMovePayload(2, [200, 201, 202])
    producer.push(first)
    producer.push(second)
    check q.len() == 2

    var consumer = q.getConsumerHere()

    var popped1 = consumer.pop()
    check popped1.isSome
    check popped1.get.tag == 1
    check popped1.get.payload == @[100, 101]

    var popped2 = consumer.pop()
    check popped2.isSome
    check popped2.get.tag == 2
    check popped2.get.payload == @[200, 201, 202]

    check q.len() == 0
    check consumer.pop().isNone

  test "non-copyable T survives MPMC segment escalation":
    # Segment size S=2 forces a segment spill on the third push: the first
    # two pushes fill the initial segment (tail 0 -> 2). The third push
    # hits `tail >= S` in the ccMulti/ccMulti branch of `push`
    # (queue.nim:1011 onward), allocates a fresh segment via
    # `newSegment[T, ccProd, ccCons, S]()`, links it via
    # `tailSegment.store(newSeg, moRelease)`, and lands its payload in
    # slot 0 of the new segment. If any branch of the spill path read the
    # in-flight `item` non-sink, the compile would fail here on a
    # non-copyable T. A clean compile + the FIFO assertion below proves
    # the move-only payload survived the segment rotation.
    var q = newQueue(Queue[MovePayload, ccMulti, ccMulti, stEager, 2, 4])
    var producer = q.getProducerHere()

    var a = makeMovePayload(10, [1, 2])
    var b = makeMovePayload(20, [3, 4, 5])
    var c = makeMovePayload(30, [6, 7, 8, 9])
    var d = makeMovePayload(40, [11])

    producer.push(a) # slot 0 of segment 1
    producer.push(b) # slot 1 of segment 1 (fills it)
    producer.push(c) # spill: alloc segment 2, land in slot 0
    producer.push(d) # slot 1 of segment 2
    check q.len() == 4

    var consumer = q.getConsumerHere()

    var popA = consumer.pop()
    check popA.isSome
    check popA.get.tag == 10
    check popA.get.payload == @[1, 2]

    var popB = consumer.pop()
    check popB.isSome
    check popB.get.tag == 20
    check popB.get.payload == @[3, 4, 5]

    # The next pop crosses the segment boundary; the moved-only payload
    # was carried through the producer's spill escalation.
    var popC = consumer.pop()
    check popC.isSome
    check popC.get.tag == 30
    check popC.get.payload == @[6, 7, 8, 9]

    var popD = consumer.pop()
    check popD.isSome
    check popD.get.tag == 40
    check popD.get.payload == @[11]

    check q.len() == 0
    check consumer.pop().isNone
