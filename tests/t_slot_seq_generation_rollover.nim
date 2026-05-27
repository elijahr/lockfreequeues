## Deterministic regression test for the original mpmc protocol bug.
##
## This test reproduces the §3 walk-through from the design doc step-by-step
## using the typestate primitives directly (no thread spawning). Three
## walkthroughs cover the three affected variants:
##
##   1. Mpmc (multi-producer, multi-consumer)
##   2. Spmc (single-producer, multi-consumer)
##   3. Mpsc (multi-producer, single-consumer)
##
## In every variant the original protocol allowed a preempted consumer's
## reservation to be silently re-claimed by a later consumer at a wrap-around
## position. The Vyukov per-slot `seq` counter prevents that because the
## post-claim, pre-completion `seq` value carries the EXACT virtual position
## the slot is armed for - any later claim observing that stale `seq` either
## rejects (consumer: diff < 0 -> Empty) or rejects (producer: diff < 0 ->
## Full). There is no path to re-claim. This test asserts that property
## deterministically.
##
## The test would FAIL on the old `committed: bool` protocol; in fact, it
## cannot even compile against that API (the field doesn't exist). It ships
## with the new code and serves as the bug-canary for any future regression.
##
## See design doc §3 (walkthrough), §10.15 (test plan), and Phase F of the
## impl plan.

import unittest2

import lockfreequeues
import lockfreequeues/atomic_dsl

import lockfreequeues/typestates/mpmc_cell
import lockfreequeues/typestates/mpmc_push
import lockfreequeues/typestates/mpmc_pop
import lockfreequeues/typestates/spmc_push
import lockfreequeues/typestates/spmc_pop
import lockfreequeues/typestates/mpsc_push
import lockfreequeues/typestates/mpsc_pop


# ---------------------------------------------------------------------------
# Mpmc walkthrough
# ---------------------------------------------------------------------------

suite "slot-seq generation rollover - Mpmc":

  test "preempted consumer cannot be re-claimed by wrap-around consumer (Mpmc)":
    # N=4 is the smallest capacity that exercises the wrap. P/C are arbitrary
    # for this single-threaded drive; we never call getProducer/getConsumer.
    var q = newMpmcQueue[int, 4, 2, 2]()
    let pushBase = cast[ptr MpmcPushBase[4, 2, 2, int]](addr q)
    let popBase = cast[ptr MpmcBase[4, 2, 2, int]](addr q)

    # ----- Phase 1: P0..P3 push items, leaving head=0, tail=4, all cells
    # holding their producer's value with seq[i] = i+1.
    for i in 0 .. 3:
      var op = mpmc_push.start[4]()
      let claim = op.tryClaim(pushBase[])
      check(claim.kind == mMPMCPushSlotClaimed)
      check(claim.mpmcpushslotclaimed.pos == uint64(i))
      discard claim.mpmcpushslotclaimed.complete(pushBase[], 100 + i)

    check(q.head.load(moRelaxed) == 0'u64)
    check(q.tail.load(moRelaxed) == 4'u64)
    for i in 0 .. 3:
      check(q.cells.cells[i].payload.seq.load(moAcquire) == uint64(i + 1))
    # Phase 1 invariant: cell[3] holds item_A = 103, seq[3] = 4.

    # ----- Consume positions 0..2 (sets up "after consuming 0..2" state).
    for i in 0 .. 2:
      var op = mpmc_pop.start[4]()
      let claim = op.tryClaim(popBase[])
      check(claim.kind == mMPMCPopSlotClaimed)
      check(claim.mpmcpopslotclaimed.pos == uint64(i))
      let val = claim.mpmcpopslotclaimed.complete(popBase[])
      check(val == 100 + i)

    check(q.head.load(moRelaxed) == 3'u64)
    check(q.tail.load(moRelaxed) == 4'u64)
    # Slots 0, 1, 2 have been re-armed: seq[i] = i + N = i + 4.
    for i in 0 .. 2:
      check(q.cells.cells[i].payload.seq.load(moAcquire) == uint64(i + 4))
    # Slot 3 is still seq=4 (no consumer has touched it).
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # ----- Phase 2: Consumer A claims slot 3 (pos=3) but DOES NOT complete.
    # Simulates A being preempted between C3 (head CAS) and C5 (seq.store).
    var opA = mpmc_pop.start[4]()
    let claimA = opA.tryClaim(popBase[])
    check(claimA.kind == mMPMCPopSlotClaimed)
    check(claimA.mpmcpopslotclaimed.pos == 3'u64)
    # Capture the SlotClaimed verb so we can complete it later (Phase 6).
    let pendingA = claimA.mpmcpopslotclaimed

    # Post-claim invariants: head advanced to 4 by A's CAS at C3. seq[3] is
    # UNCHANGED because A has not executed C5 yet.
    check(q.head.load(moRelaxed) == 4'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # ----- Phase 3: Simulate other threads cycling. Manually advance head to
    # 7 and tail to 7, and re-arm slots 0, 1, 2 to the seq values they would
    # carry after one more push+pop cycle each. We CANNOT actually push at
    # virtual position 7 (slot 3) without releasing slot 3 first; the
    # protocol correctly blocks that. So we simulate by direct cursor stores
    # plus per-slot seq updates for slots 0,1,2.
    #
    # Walkthrough state we are forging:
    #   - Pushes at virtual positions 4,5,6 -> slots 0,1,2 -> seq becomes
    #     5,6,7 after each push (seq = pos + 1).
    #   - Pops at virtual positions 4,5,6 -> slots 0,1,2 -> seq becomes
    #     8,9,10 after each pop (seq = pos + N).
    # So slots 0,1,2 end with seq = 4+N, 5+N, 6+N = 8, 9, 10.
    # Slot 3 stays seq=4 (consumer A still preempted).
    # head and tail both reach 7.
    q.cells.cells[0].payload.seq.store(8'u64, moRelease)
    q.cells.cells[1].payload.seq.store(9'u64, moRelease)
    q.cells.cells[2].payload.seq.store(10'u64, moRelease)
    q.head.store(7'u64, moRelease)
    q.tail.store(7'u64, moRelease)

    # ----- Phase 4: Consumer B at pos=7 (slot 3). Must observe Empty.
    # diff = seq - (pos + 1) = 4 - 8 = -4. Critical: NOT a stale-ready
    # claim of slot 3.
    var opB = mpmc_pop.start[4]()
    let claimB = opB.tryClaim(popBase[])
    check(claimB.kind == mMPMCPopEmpty)

    # head must NOT have advanced (Empty is a no-op on the cursor).
    check(q.head.load(moRelaxed) == 7'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # ----- Phase 5: Producer P1 at pos=7 (slot 3). Must observe Full.
    # diff = seq - pos = 4 - 7 = -3. Slot reserved by pending consumer.
    var opP1 = mpmc_push.start[4]()
    let claimP1 = opP1.tryClaim(pushBase[])
    check(claimP1.kind == mMPMCPushFull)

    # tail must NOT have advanced (Full is a no-op on the cursor).
    check(q.tail.load(moRelaxed) == 7'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # ----- Phase 6: Consumer A finally completes (executes C5).
    # cell[3].data is whatever A was reading; Mpmc's complete returns it.
    let valA = pendingA.complete(popBase[])
    check(valA == 103) # The original item_A pushed in Phase 1.
    # seq[3] is now pos + N = 3 + 4 = 7, matching the next producer
    # generation's expected diff=0 entry condition.
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 7'u64)

    # ----- Phase 7: Producer P1 retries at pos=7 (slot 3). Must succeed
    # (diff = 7 - 7 = 0) and publish seq=8.
    var opP1b = mpmc_push.start[4]()
    let claimP1b = opP1b.tryClaim(pushBase[])
    check(claimP1b.kind == mMPMCPushSlotClaimed)
    check(claimP1b.mpmcpushslotclaimed.pos == 7'u64)
    discard claimP1b.mpmcpushslotclaimed.complete(pushBase[], 999)
    check(q.tail.load(moRelaxed) == 8'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 8'u64)

    # Consumer B retries at pos=7 (slot 3). Must succeed (diff = 8 - 8 = 0)
    # and observe item_B = 999.
    var opBb = mpmc_pop.start[4]()
    let claimBb = opBb.tryClaim(popBase[])
    check(claimBb.kind == mMPMCPopSlotClaimed)
    check(claimBb.mpmcpopslotclaimed.pos == 7'u64)
    let valB = claimBb.mpmcpopslotclaimed.complete(popBase[])
    check(valB == 999)
    check(q.head.load(moRelaxed) == 8'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 11'u64) # 7 + N


# ---------------------------------------------------------------------------
# Spmc walkthrough (single producer, multi-consumer)
# ---------------------------------------------------------------------------

suite "slot-seq generation rollover - Spmc":

  test "preempted consumer cannot be re-claimed by wrap-around consumer (Spmc)":
    # Same trace structure as Mpmc, but the producer side uses the
    # spmc_push (defensive-CAS) verb. The bug shape is identical - the
    # consumer side is what re-armed the slot in the original protocol.
    var q = newSpmcQueue[int, 4, 2]()
    let pushBase = cast[ptr SpmcPushBase[4, 2, int]](addr q)
    let popBase = cast[ptr SpmcBase[4, 2, int]](addr q)

    # Phase 1: push 4 items via the SPMC push verb.
    for i in 0 .. 3:
      var op = spmc_push.start[4]()
      let claim = op.tryClaim(pushBase[])
      check(claim.kind == sSPMCPushSlotClaimed)
      check(claim.spmcpushslotclaimed.pos == uint64(i))
      discard claim.spmcpushslotclaimed.complete(pushBase[], 200 + i)

    check(q.tail.load(moRelaxed) == 4'u64)
    for i in 0 .. 3:
      check(q.cells.cells[i].payload.seq.load(moAcquire) == uint64(i + 1))

    # Consume positions 0..2 to set up head=3.
    for i in 0 .. 2:
      var op = spmc_pop.start[4]()
      let claim = op.tryClaim(popBase[])
      check(claim.kind == sSPMCPopSlotClaimed)
      check(claim.spmcpopslotclaimed.pos == uint64(i))
      let val = claim.spmcpopslotclaimed.complete(popBase[])
      check(val == 200 + i)

    check(q.head.load(moRelaxed) == 3'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 2: Consumer A claims slot 3, holds completion.
    var opA = spmc_pop.start[4]()
    let claimA = opA.tryClaim(popBase[])
    check(claimA.kind == sSPMCPopSlotClaimed)
    check(claimA.spmcpopslotclaimed.pos == 3'u64)
    let pendingA = claimA.spmcpopslotclaimed
    check(q.head.load(moRelaxed) == 4'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 3: forge state to simulate cycling, head=tail=7.
    q.cells.cells[0].payload.seq.store(8'u64, moRelease)
    q.cells.cells[1].payload.seq.store(9'u64, moRelease)
    q.cells.cells[2].payload.seq.store(10'u64, moRelease)
    q.head.store(7'u64, moRelease)
    q.tail.store(7'u64, moRelease)

    # Phase 4: Consumer B at pos=7 -> Empty.
    var opB = spmc_pop.start[4]()
    let claimB = opB.tryClaim(popBase[])
    check(claimB.kind == sSPMCPopEmpty)
    check(q.head.load(moRelaxed) == 7'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 5: Producer at pos=7 -> Full.
    var opP = spmc_push.start[4]()
    let claimP = opP.tryClaim(pushBase[])
    check(claimP.kind == sSPMCPushFull)
    check(q.tail.load(moRelaxed) == 7'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 6: Consumer A completes.
    let valA = pendingA.complete(popBase[])
    check(valA == 203)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 7'u64)

    # Phase 7: producer + consumer at pos=7 succeed in order.
    var opPb = spmc_push.start[4]()
    let claimPb = opPb.tryClaim(pushBase[])
    check(claimPb.kind == sSPMCPushSlotClaimed)
    check(claimPb.spmcpushslotclaimed.pos == 7'u64)
    discard claimPb.spmcpushslotclaimed.complete(pushBase[], 888)
    check(q.tail.load(moRelaxed) == 8'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 8'u64)

    var opBb = spmc_pop.start[4]()
    let claimBb = opBb.tryClaim(popBase[])
    check(claimBb.kind == sSPMCPopSlotClaimed)
    check(claimBb.spmcpopslotclaimed.pos == 7'u64)
    let valB = claimBb.spmcpopslotclaimed.complete(popBase[])
    check(valB == 888)
    check(q.head.load(moRelaxed) == 8'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 11'u64)


# ---------------------------------------------------------------------------
# Mpsc walkthrough (multi-producer, single consumer)
# ---------------------------------------------------------------------------

suite "slot-seq generation rollover - Mpsc":

  test "preempted consumer cannot be re-claimed by wrap-around consumer (Mpsc)":
    # Same trace structure. Producer side uses mpsc_push; consumer side
    # uses mpsc_pop (defensive-CAS form per design §10.9).
    var q = newMpscQueue[int, 4, 2]()
    let pushBase = cast[ptr MpscPushBase[4, 2, int]](addr q)
    let popBase = cast[ptr MpscBase[4, 2, int]](addr q)

    # Phase 1: push 4 items.
    for i in 0 .. 3:
      var op = mpsc_push.start[4]()
      let claim = op.tryClaim(pushBase[])
      check(claim.kind == mMPSCPushSlotClaimed)
      check(claim.mpscpushslotclaimed.pos == uint64(i))
      discard claim.mpscpushslotclaimed.complete(pushBase[], 300 + i)

    check(q.tail.load(moRelaxed) == 4'u64)
    for i in 0 .. 3:
      check(q.cells.cells[i].payload.seq.load(moAcquire) == uint64(i + 1))

    # Consume positions 0..2 to set up head=3.
    for i in 0 .. 2:
      var op = mpsc_pop.start[4]()
      let claim = op.tryClaim(popBase[])
      check(claim.kind == mMPSCPopSlotClaimed)
      check(claim.mpscpopslotclaimed.pos == uint64(i))
      let val = claim.mpscpopslotclaimed.complete(popBase[])
      check(val == 300 + i)

    check(q.head.load(moRelaxed) == 3'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 2: Consumer A claims slot 3, holds completion.
    var opA = mpsc_pop.start[4]()
    let claimA = opA.tryClaim(popBase[])
    check(claimA.kind == mMPSCPopSlotClaimed)
    check(claimA.mpscpopslotclaimed.pos == 3'u64)
    let pendingA = claimA.mpscpopslotclaimed
    check(q.head.load(moRelaxed) == 4'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 3: forge state to simulate cycling, head=tail=7.
    q.cells.cells[0].payload.seq.store(8'u64, moRelease)
    q.cells.cells[1].payload.seq.store(9'u64, moRelease)
    q.cells.cells[2].payload.seq.store(10'u64, moRelease)
    q.head.store(7'u64, moRelease)
    q.tail.store(7'u64, moRelease)

    # Phase 4: Consumer B at pos=7 -> Empty.
    var opB = mpsc_pop.start[4]()
    let claimB = opB.tryClaim(popBase[])
    check(claimB.kind == mMPSCPopEmpty)
    check(q.head.load(moRelaxed) == 7'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 5: Producer at pos=7 -> Full.
    var opP = mpsc_push.start[4]()
    let claimP = opP.tryClaim(pushBase[])
    check(claimP.kind == mMPSCPushFull)
    check(q.tail.load(moRelaxed) == 7'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 4'u64)

    # Phase 6: Consumer A completes.
    let valA = pendingA.complete(popBase[])
    check(valA == 303)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 7'u64)

    # Phase 7: producer + consumer at pos=7 succeed in order.
    var opPb = mpsc_push.start[4]()
    let claimPb = opPb.tryClaim(pushBase[])
    check(claimPb.kind == mMPSCPushSlotClaimed)
    check(claimPb.mpscpushslotclaimed.pos == 7'u64)
    discard claimPb.mpscpushslotclaimed.complete(pushBase[], 777)
    check(q.tail.load(moRelaxed) == 8'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 8'u64)

    var opBb = mpsc_pop.start[4]()
    let claimBb = opBb.tryClaim(popBase[])
    check(claimBb.kind == mMPSCPopSlotClaimed)
    check(claimBb.mpscpopslotclaimed.pos == 7'u64)
    let valB = claimBb.mpscpopslotclaimed.complete(popBase[])
    check(valB == 777)
    check(q.head.load(moRelaxed) == 8'u64)
    check(q.cells.cells[3].payload.seq.load(moAcquire) == 11'u64)
