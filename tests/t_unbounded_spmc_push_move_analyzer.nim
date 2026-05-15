## Task 11 (I1) — atomicArc move-analyzer baseline for unbounded SPMC.
##
## Characterization test: demonstrates the SPMC push/pop path can carry a
## genuinely non-copyable, sink-only `T` under `--mm:atomicArc --threads:on`.
##
## A type whose `=copy` is disabled (`{.error.}`) cannot be copied by the
## compiler. If the SPMC facade's push parameter and the typestate's
## `writeItem(item: T)` chain *did* require a copy at any step, this file
## would fail to COMPILE under atomicArc's move-analyzer with a clear
## "'=copy' is not available" error. A clean compile + a passing pop
## therefore proves end-to-end move-only viability.
##
## Compile both:
##   nim c --mm:atomicArc --threads:on -r tests/t_unbounded_spmc_push_move_analyzer.nim
##   nim c --threads:on -r tests/t_unbounded_spmc_push_move_analyzer.nim
##
## Case A baseline: this test is expected to PASS on first run with no
## source changes. A compile error mentioning copy/clone of `MovePayload`
## indicates scope creep into Task 5 (the production push/pop chain is
## not yet sink-clean) and should be surfaced to the orchestrator.

import options
import unittest2
import lockfreequeues/atomic_dsl

import debra
import lockfreequeues/unbounded_sipmuc
# Task 12 (C4 propagation test): the production `Segment` / `cellState` from
# unbounded_sipmuc.nim are non-exported. The typestate-mirror `Segment*` /
# `cellState*` from `unbounded_spmc_push` are byte-layout-compatible: the
# static asserts at `unbounded_sipmuc.nim:166-174` confirm `sizeof(Segment)`
# equality plus `offsetOf` on `data`, `next`, `tail`, `consumerHead`.
# `cellState` and `closed` offset equivalence is not directly asserted but
# follows transitively from sizeof equality combined with identical field
# declarations and `{.align: CacheLineBytes.}` pragmas in both type decls
# (production `Segment` at `unbounded_sipmuc.nim:91, 93` and typestate-mirror
# `Segment*` at `unbounded_spmc_push.nim:54, 56`). Cast through the typestate
# mirror to pre-stage CellClosed without touching production-private symbols.
import lockfreequeues/typestates/unbounded_spmc_push

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
  MovePayload = object
    tag: int
    payload: seq[int]

proc `=copy`(dst: var MovePayload, src: MovePayload) {.error.}
  ## Disable copy. If the SPMC push/pop chain ever needs to copy a
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

suite "Task 11 LCRQ SPMC move-analyzer baseline (I1)":
  test "single push/pop carries a non-copyable MovePayload end-to-end":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, MovePayload, 4](addr manager)

    # Construct, then push. `item` is at its last use on the `push` line,
    # so under arc/atomicArc the move analyzer must turn the parameter
    # bind into a sink. If it cannot, this line fails to compile.
    var item = makeMovePayload(7, [10, 20, 30])
    queue.push(item)
    check queue.len == 1

    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)
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
    var queue = newUnboundedSipmuc[16, MovePayload, 4](addr manager)

    var first = makeMovePayload(1, [100, 101])
    var second = makeMovePayload(2, [200, 201, 202])
    queue.push(first)
    queue.push(second)
    check queue.len == 2

    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

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

suite "Task 12 SPMC pendingItem propagation through escalation (I1, C4)":
  test "non-copyable T survives closure escalation (S=2 forces escalation fast)":
    ## C4: pendingItem must thread through every typestate transition under
    ## non-copyable T. With S=2 we pre-close both cells of the head segment,
    ## forcing the producer's publish-CAS to fail both times. After
    ## `closureRetryCount >= StarvingThreshold` the producer escalates,
    ## allocates a fresh segment, and re-publishes `pendingItem` there.
    ## A `=copy` violation at ANY of the propagation sites
    ## (`loadSegment`/`checkFull`/`allocateNewSegment`/`closeSegmentDone`,
    ## §1440-1444 of the plan) would fail compile under `--mm:atomicArc`;
    ## a value-corruption bug would fail one of the new-segment field
    ## checks below.
    ##
    ## NOTE: this test does NOT pop. Pre-staging `CellClosed` on the head
    ## segment violates the LCRQ consumer-side invariant that `cellState`
    ## transitions `CellEmpty -> CellClosed` are only ever issued by a
    ## consumer's close-CAS (per the consumer close-CAS at
    ## `unbounded_spmc_pop.nim:321-322` and the invariant comment block at
    ## `unbounded_spmc_pop.nim:332-336`; the doAssert at line 337 sanity-
    ## checks the related CAS-failure case but does not itself establish
    ## the consumer-only invariant). Verifying the propagated value
    ## directly via the new tail segment (cellState + data) sidesteps the
    ## downstream pop assertion without losing assertion strength: a
    ## broken `pendingItem` thread would leave the new segment empty or
    ## with the wrong value, and `data[0]`'s field-by-field equality
    ## catches a corrupted/zeroed/scrambled payload.
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[2, MovePayload, 4](addr manager)

    # Pre-close both cells of the head segment via the typestate-mirror
    # `Segment*[2, MovePayload]` (byte-layout-compatible per the static
    # asserts at `src/lockfreequeues/unbounded_sipmuc.nim:166-174`, which
    # cover sizeof + offsetOf on data/next/tail/consumerHead; cellState and
    # closed equivalence follows transitively from sizeof equality + the
    # mirrored field-order and `{.align: CacheLineBytes.}` pragmas in both
    # type declarations).
    let headSeg = cast[ptr Segment[2, MovePayload]](headSegmentForTest(queue))
    headSeg.cellState[0].store(CellClosed, moRelaxed)
    headSeg.cellState[1].store(CellClosed, moRelaxed)

    # Push a non-copyable item. writeItem on the head segment:
    #   slot 0 entry-fetchAdd -> CellClosed -> publish-CAS fails
    #     -> closureRetryCount=1, observedTail=1, S=2: continue
    #   slot 1 Shape A fetchAdd -> CellClosed -> publish-CAS fails
    #     -> closureRetryCount=2 >= StarvingThreshold=2: SegmentClosed
    # The facade then drives the escalation chain
    # SegmentClosed -> Ready -> SegmentLoaded -> SegmentFull -> Ready
    # (new segment) -> SlotReady -> writeItem (publishes on new segment).
    # Each `->` arrow's typestate transition carries `pendingItem` by
    # sink move; a missing `move(...)` at any of the §1440-1444 sites
    # would fail compile under `--mm:atomicArc`.
    var item = makeMovePayload(99, [7, 8, 9])
    queue.push(item)

    # The head segment must be marked closed (escalation T&S landed on
    # `seg.closed`), and the new segment must hold the propagated item
    # at slot 0 with CellFilled.
    check headSeg.closed.load(moRelaxed) == true
    let newSeg = cast[ptr Segment[2, MovePayload]](headSeg.next.load(moRelaxed))
    check newSeg != nil
    check newSeg.cellState[0].load(moRelaxed) == CellFilled
    # Full-field assertion on the propagated payload. Field reads on
    # `data[0]` produce a borrow (no copy), so non-copyable T is fine.
    check newSeg.data[0].tag == 99
    check newSeg.data[0].payload == @[7, 8, 9]
