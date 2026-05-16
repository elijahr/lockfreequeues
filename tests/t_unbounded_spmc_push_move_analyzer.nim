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

import debra
import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_sipmuc

template checkPinNotLeaked[MT: static int](
    mgr: var DebraManager[MT], handleIdx: int
) =
  ## I-1: explicit pin-leak assertion. After a facade push/pop or
  ## typestate verb chain completes, the thread's pinned flag MUST be
  ## back to false. DEBRA's =destroy panic-on-leak is an indirect
  ## backstop that only fires at process shutdown; this template fires
  ## the assertion at the test site so a regression surfaces immediately.
  check mgr.threads[handleIdx].pinned.load(moAcquire) == false
  check mgr.threads[handleIdx].neutralized.load(moAcquire) == false

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
    # I-1: probe handle for push-side pin introspection (SPMC push has
    # no withPin: scope; this is a regression guard).
    let probeHandle = registerThread(manager)
    var item = makeMovePayload(7, [10, 20, 30])
    queue.push(item)
    check queue.len == 1
    # I-1: SPMC push must not have set this thread's pin flag.
    checkPinNotLeaked(manager, probeHandle.idx)

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
    # I-1: consumer pop's withPin: scope must have released the pin.
    checkPinNotLeaked(manager, handle.idx)

  test "two sequential pushes/pops preserve FIFO with non-copyable T":
    var manager = initDebraManager[4]()
    var queue = newUnboundedSipmuc[16, MovePayload, 4](addr manager)

    # I-1: probe handle for push-side pin introspection (SPMC push has
    # no withPin: scope; regression guard).
    let probeHandle = registerThread(manager)
    var first = makeMovePayload(1, [100, 101])
    var second = makeMovePayload(2, [200, 201, 202])
    queue.push(first)
    queue.push(second)
    check queue.len == 2
    # I-1: neither push opened a pin scope.
    checkPinNotLeaked(manager, probeHandle.idx)

    let handle = registerThread(manager)
    var consumer = queue.getConsumer(handle)

    var popped1 = consumer.pop()
    check popped1.isSome
    check popped1.get.tag == 1
    check popped1.get.payload == @[100, 101]
    # I-1: pop's withPin: scope released after first pop.
    checkPinNotLeaked(manager, handle.idx)

    var popped2 = consumer.pop()
    check popped2.isSome
    check popped2.get.tag == 2
    check popped2.get.payload == @[200, 201, 202]

    check queue.len == 0
    check consumer.pop().isNone
    # I-1: pin released after both Some and None pop paths.
    checkPinNotLeaked(manager, handle.idx)
