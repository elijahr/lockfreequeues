## Move-analyzer baseline for v5 bounded MPMC `BQueue`.
##
## Bounded-side twin of `tests/t_queue_unbounded_mpmc_move_analyzer.nim`.
## Demonstrates that v5's bounded MPMC push/pop chain can carry a genuinely
## non-copyable, sink-only `T` end-to-end through the Vyukov per-slot
## sequence-counter protocol (`src/lockfreequeues/typestates/mpmc_push.nim`,
## `mpmc_pop.nim`, `mpmc_cell.nim`).
##
## A type whose `=copy` is disabled (`{.error.}`) cannot be copied by the
## compiler. If the Bound[MPMC].push parameter binding, the typestate's
## `tryClaim` -> `writeData` -> `complete` chain (which writes `item` into
## `queue.cells.dataPtr(op.slot)[]` at P4 and re-reads after the publish-CAS
## under producer-vs-producer contention), or the consumer-side `complete`
## chain (which reads `queue.cells.dataPtr(op.slot)[]` at C4 and re-arms the
## seq counter) ever required a copy at any step, this file would fail to
## COMPILE under atomicArc's move-analyzer with a clear "'=copy' is not
## available" error. A clean compile + passing pops therefore proves
## end-to-end move-only viability for the bounded MPMC path.
##
## Compile (the gate this test enforces):
##   nim c --mm:atomicArc --threads:on --path:src \
##     -r tests/t_bqueue_mpmc_move_analyzer.nim
##
## Expected: PASS on the v5 HEAD. A compile error mentioning copy/clone of
## `MovePayload` indicates a regression in v5's bounded MPMC push/pop chain.

import options
import unittest2

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

type
  ## Move-only payload — same shape as the unbounded MPMC analog.
  ## `=copy` disabled; any attempted copy by the compiler is a hard error.
  ## Owns a `seq[int]` so post-pop field assertions exercise the real
  ## moved-from boundary (not a trivially-shuffleable int that the
  ## compiler could shunt through a register without ever invoking
  ## `=sink`).
  MovePayload = object
    tag: int
    payload: seq[int]

proc `=copy`(dst: var MovePayload, src: MovePayload) {.error.}
  ## Disable copy. If v5's bounded MPMC push/pop chain ever needs to copy a
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

suite "v5 bounded MPMC move-analyzer baseline":
  test "single push/pop carries a non-copyable MovePayload end-to-end":
    var q = initBQueue[MovePayload, ccMulti, ccMulti, 16, 4, 4]()
    var producer = q.getProducerHere(0)
    var item = makeMovePayload(7, [10, 20, 30])
    check producer.push(item)

    var consumer = q.getConsumerHere(0)
    var popped = consumer.pop()

    check popped.isSome
    check popped.get.tag == 7
    check popped.get.payload == @[10, 20, 30]

  test "two sequential pushes/pops preserve FIFO with non-copyable T":
    var q = initBQueue[MovePayload, ccMulti, ccMulti, 16, 4, 4]()
    var producer = q.getProducerHere(0)
    var first = makeMovePayload(1, [100, 101])
    var second = makeMovePayload(2, [200, 201, 202])
    check producer.push(first)
    check producer.push(second)

    var consumer = q.getConsumerHere(0)

    var popped1 = consumer.pop()
    check popped1.isSome
    check popped1.get.tag == 1
    check popped1.get.payload == @[100, 101]

    var popped2 = consumer.pop()
    check popped2.isSome
    check popped2.get.tag == 2
    check popped2.get.payload == @[200, 201, 202]

    check consumer.pop().isNone

  test "non-copyable T survives a wraparound cycle":
    # N=4: push 4 items (fills the ring), pop 4 (empties), push 2 more
    # (wraps around through seq-counter generation 1 on slots 0-1). The
    # per-cell `cellSeq` counter advances through generation 1 between
    # the two push cycles (see typestates/mpmc_cell.nim). If any part of
    # the wraparound path re-read `item` non-sink after the seq-counter
    # advance, the compile would fail here on a non-copyable T.
    var q = initBQueue[MovePayload, ccMulti, ccMulti, 4, 4, 4]()
    var producer = q.getProducerHere(0)

    # First cycle: fill the ring.
    var a = makeMovePayload(10, [1, 2])
    var b = makeMovePayload(20, [3, 4, 5])
    var c = makeMovePayload(30, [6])
    var d = makeMovePayload(40, [7, 8, 9, 10])
    check producer.push(a)
    check producer.push(b)
    check producer.push(c)
    check producer.push(d)

    # Drain the ring.
    var consumer = q.getConsumerHere(0)
    var pA = consumer.pop()
    check pA.isSome
    check pA.get.tag == 10
    check pA.get.payload == @[1, 2]
    var pB = consumer.pop()
    check pB.isSome
    check pB.get.tag == 20
    check pB.get.payload == @[3, 4, 5]
    var pC = consumer.pop()
    check pC.isSome
    check pC.get.tag == 30
    check pC.get.payload == @[6]
    var pD = consumer.pop()
    check pD.isSome
    check pD.get.tag == 40
    check pD.get.payload == @[7, 8, 9, 10]

    # Wraparound: push two more items into slots 0-1 of generation 1.
    var e = makeMovePayload(50, [11, 12])
    var f = makeMovePayload(60, [13])
    check producer.push(e)
    check producer.push(f)

    var pE = consumer.pop()
    check pE.isSome
    check pE.get.tag == 50
    check pE.get.payload == @[11, 12]
    var pF = consumer.pop()
    check pF.isSome
    check pF.get.tag == 60
    check pF.get.payload == @[13]

    check consumer.pop().isNone
