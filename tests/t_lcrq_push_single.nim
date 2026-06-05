## Unit test: MPMC producer publish writes to LCRQ cell.
##
## Phase B Task T5 of the strict-LCRQ migration. After T5 wires
## the `tryPublish(seg.cells[mySlot], expectedSeq=0, value=item)`
## call into the MPMC arm of `push` (replacing the T3 `wasMoved(item)`
## stub), a single-producer push must transition cell[slot] from
## (seq=0, default(T)) → (seq=1, value).
##
## Design references:
##   §2.5.1 — state machine (publish: seq 0 → 1, payload stored)
##   §4     — producer publish path
##   §8     — memory ordering (success=moRelease, failure=moRelaxed)
##
## Pre-T5 baseline: the T3 stub `wasMoved(item)` dropped the value
## via sink destructor; cell[slot] stayed (0, 0) and itemCount
## incremented (so queue.len lied). Assertion 1 (seq==1) is the
## primary tooth.

import std/unittest

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/endpoint
import lockfreequeues/internal/pinscope_stub
import debra as debra_mod
from debra import DebraManager, initDebraManager
from debra/atomics import load, moRelaxed, Pair

suite "T5: MPMC producer publish writes to LCRQ cell (design §2.5.1, §4)":
  test "T5.P1: single push transitions cell[0] from (0, 0) to (1, 42) for T=int":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    let segPtr = cast[ptr Segment[int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, 16]](queue.headSegmentForTest())
    check segPtr != nil

    # Empty-cell precondition: every slot is (seq=0, default(T)=0).
    for i in 0 ..< 16:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 0'u64
      check observed.second == 0

    var producer = queue.getProducerHere()
    producer.push(42)

    # Slot 0 is the first claimed slot under single-producer push.
    # Post-publish: (seq=1, value=42) per design §2.5.1.
    let after = load(segPtr.cells[0], moRelaxed)
    check after.first == 1'u64
    check after.second == 42

    # Every other slot remains untouched.
    for i in 1 ..< 16:
      let other = load(segPtr.cells[i], moRelaxed)
      check other.first == 0'u64
      check other.second == 0

  test "T5.P2: four sequential pushes fill cells[0..3] with (seq=1, value=i+1)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    let segPtr = cast[ptr Segment[int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, 16]](queue.headSegmentForTest())
    check segPtr != nil

    var producer = queue.getProducerHere()
    for i in 1 .. 4:
      producer.push(i)

    # Cells 0..3 each hold (seq=1, value=i+1); cells 4..15 untouched.
    for i in 0 ..< 4:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 1'u64
      check observed.second == i + 1

    for i in 4 ..< 16:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 0'u64
      check observed.second == 0
