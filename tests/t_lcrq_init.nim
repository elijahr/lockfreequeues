## Unit test: MPMC newSegment cell-init contract.
##
## Phase B Task T4 of the strict-LCRQ migration. After T4 wires the
## `result.cells[i] = (seq=0, default(T))` store loop into the MPMC
## arm of `newSegment`, every slot of a freshly-allocated MPMC
## segment MUST observe the design §2.5.1 empty-cell state:
##   - `seq == 0` (low 63 bits of the epoch counter == 0)
##   - `payload == default(T)`
##
## Why this test passes against allocAligned zero-init even before T4:
## `allocAligned[Segment[T, ccMulti, ccMulti, S]]` already zeros the
## page, and `(seq=0, default(int)=0)` IS the all-zero bit pattern.
## The pre-T4 stub (`discard`) and the T4 explicit-store loop are
## observationally indistinguishable on T=int with this allocator.
## The test still earns its keep as a regression guard: if a future
## change swaps `allocAligned` for `alloc` (no zero-init), drops the
## init loop, or introduces a non-zero empty sentinel without
## reseeding cells, this test fails. The teeth of the test were
## verified by a temporary local mutation during T4 development
## (store `Pair(first: 7'u64, second: 99)` instead of zero — the test
## failed on assertion 1; restoring the zero store made it pass).
##
## Design references:
##   §2.5.1 — state machine (empty cell = (seq=0, default(T)))
##   §4     — init path / progress argument

import std/unittest

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import debra as debra_mod
from debra import DebraManager, initDebraManager
from debra/atomics import load, moRelaxed, Pair

suite "T4: MPMC newSegment cell-init contract (design §2.5.1)":
  test "T4.I1: every cell of a fresh MPMC segment is (seq=0, default(T)=0) for T=int":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    let segPtr = cast[ptr Segment[int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, 16]](queue.headSegmentForTest())
    check segPtr != nil
    for i in 0 ..< 16:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 0'u
      check observed.second == 0

  test "T4.I2: every cell of a fresh MPMC segment is (seq=0, default(T)=nil) for T=ptr int":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[ptr int, stEager, 16, 4](addr manager)
    let segPtr = cast[ptr Segment[
      ptr int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, 16
    ]](queue.headSegmentForTest())
    check segPtr != nil
    let nilPtr: ptr int = nil
    for i in 0 ..< 16:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 0'u
      check observed.second == nilPtr
