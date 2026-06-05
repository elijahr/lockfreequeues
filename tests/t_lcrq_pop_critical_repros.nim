## Cycle 4 — Gemini critical findings deterministic repros.
##
## Background
## ----------
## Gemini PR #32 cycle-3 review surfaced two CRITICAL findings against
## the MPMC pop fast-path in `queue.nim`:
##
##   CRIT-1: livelock in `waitForPublish` (queue.nim ~1644). If a
##     producer wins `seg.tail.compareExchange` to reserve slot k but
##     stalls indefinitely before calling `tryPublish`, a consumer
##     that subsequently wins `prevConsumerIdx.compareExchange` on
##     mySlot=k enters the inner `waitForPublish` loop and spins
##     forever on `cells[k].first != 0`. There is no bound, no
##     close-on-empty escalation, no segment-advance escape.
##
##   CRIT-2: premature segment retirement (queue.nim ~1614). The
##     fast-path post-`prevConsumerIdx`-CAS case-(a) branch
##     (CLOSED_BIT observed at mySlot=k) retires the segment via
##     `retireOnCAS` and advances to `nextSeg`. But cells at slot
##     indices > k inside the retired segment may already hold
##     published values from producers that successfully `tryPublish`'d
##     before the slow-path peer closed slot k. Those values are
##     unreachable after `retireOnCAS` succeeds.
##
## Test strategy
## -------------
## Both repros use the `headSegmentForTest()` accessor + cast to
## `ptr Segment[T, ccMulti, ccMulti, S]` (established pattern in
## `t_lcrq_init.nim` and `t_lcrq_push_single.nim`) to manipulate
## raw segment state, simulating the race-window outcomes without
## thread orchestration:
##
##   CR-1: simulate "producer reserved-but-not-published" by directly
##     advancing `segPtr.tail` past slot 0 while leaving
##     `segPtr.cells[0]` at the empty (seq=0, default(T)) state. A
##     subsequent pop() on the fast path would reach `waitForPublish`
##     and spin. Run pop() in a background thread; assert it
##     completes within a bounded wall-clock budget. Pre-fix: pop
##     never returns (timeout fires). Post-fix: pop returns
##     none(T) after bounded spins (close-on-empty escalation) OR
##     some(T) if the cell becomes published.
##
##   CR-2: hand-craft a partially-published-then-closed segment:
##     slot 0 = CLOSED, slots 1..3 = published, with a successor
##     segment linked via `seg.next`. A pop call enters the
##     fast-path, sees CLOSED at slot 0, retires seg, and advances
##     to the successor — losing the values at slots 1..3 in the
##     retired segment. Pre-fix: pop returns the successor's first
##     value (skipping over slots 1..3). Post-fix: pop returns
##     slot 1's value (`some(42)`), then slot 2 (`some(43)`), then
##     slot 3 (`some(44)`), then the successor's value.
##
## Design references
## -----------------
##   §5.3 — MPMC pop fast-path case-(a) [CLOSED] and case-(b) [empty]
##   §5.2 — MPMC pop slow-path (close-on-empty + inline-skip)
##   §4   — close-on-empty contract (permanent close)
##   §7.1 — StarvingThreshold = S (slow-path close budget)

import std/options
import std/os
import std/unittest

import debra/atomics

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/endpoint
import lockfreequeues/internal/pinscope_stub
import debra as debra_mod
from debra import DebraManager, initDebraManager

const S = 8

type
  SegPtr = ptr Segment[int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, S]

  PopCtx = object
    queue: ptr Queue[int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, stEager, S, 4]
    done: ptr Atomic[bool]
    result: ptr Atomic[int] # -1 = none, otherwise some(value)

proc popWorker(ctx: ptr PopCtx) {.thread.} =
  {.cast(gcsafe).}:
    var consumer = ctx.queue[].getConsumerHere()
    let r = consumer.pop()
    if r.isSome:
      ctx.result[].store(r.get, moRelease)
    else:
      ctx.result[].store(-1, moRelease)
    ctx.done[].store(true, moRelease)

suite "Cycle 4 — Gemini critical-finding deterministic repros":
  test "CR-1: waitForPublish bounded under producer-stall simulation":
    # Repro for CRIT-1 (waitForPublish livelock). We simulate the
    # "producer reserved slot 0 via tail-CAS but never published"
    # state by directly advancing seg.tail to 1 without filling
    # cells[0]. A consumer entering the fast-path will:
    #   * see tail=1, mySlot=0, mySlot < tail → fast-path entry
    #   * prevConsumerIdx.CAS(-1, 0) succeeds
    #   * tryClaim(cells[0], 0) fails (cell is empty: seq=0, but
    #     tryClaim expects seq to transition 0→1 with a value;
    #     since seq is still 0, the DWCAS sees (0, 0) but the
    #     desired is (1, value) so the CAS observed value is
    #     (0, 0) — none(T))
    #   * recheck shows seq=0, not CLOSED_BIT → falls through
    #     to `waitForPublish` block
    # Pre-fix: waitForPublish spins forever on `inner.first != 0`.
    # Post-fix: bounded spin + close-on-empty escalation should
    # return either none(T) (if close-on-empty succeeded and seg
    # had no successor) or after segment advance.
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, S, 4](addr manager)
    let segPtr = cast[SegPtr](queue.headSegmentForTest())
    check segPtr != nil

    # Simulate producer's tail-CAS without tryPublish.
    segPtr.tail.store(1, moRelaxed)

    var done: Atomic[bool]
    var resultSlot: Atomic[int]
    done.store(false, moRelaxed)
    resultSlot.store(-99, moRelaxed) # sentinel: pop never called

    var ctx = PopCtx(queue: addr queue, done: addr done, result: addr resultSlot)

    var th: Thread[ptr PopCtx]
    createThread(th, popWorker, addr ctx)

    # Wall-clock budget: 2000ms is far longer than any sane
    # bounded-spin escalation. Pre-fix this fires forever.
    var elapsedMs = 0
    while elapsedMs < 2000:
      if done.load(moAcquire):
        break
      sleep(20)
      elapsedMs += 20

    let completed = done.load(moAcquire)
    check completed
    if completed:
      joinThread(th)
      # Post-fix expectation: pop returns none(T) (sentinel -1) after
      # escalation. Some implementations may return some(T) if a peer
      # actor finishes the publish during the spin — but here we
      # never called tryPublish, so the only correct post-fix outcome
      # is none(T).
      check resultSlot.load(moAcquire) == -1
    # Pre-fix path (not completed): thread is stuck in waitForPublish.
    # We cannot safely join it — the test process will hang on exit.
    # The `check completed` above will have already failed in that
    # case, so the test reports failure even though the worker thread
    # remains parked. The unittest harness will exit and the OS will
    # reap the stuck thread when the process terminates.

  test "CR-2: closed-at-k does not orphan published-at-(k+1..S-1)":
    # Repro for CRIT-2 (premature segment retirement). We craft a
    # head segment with:
    #   * cells[0] = CLOSED_BIT (close sentinel)
    #   * cells[1] = (seq=1, value=42)
    #   * cells[2] = (seq=1, value=43)
    #   * cells[3] = (seq=1, value=44)
    #   * cells[4..7] = (0, 0)
    #   * tail = 4 (producers reserved + (for slots 1..3) published)
    #   * prevConsumerIdx = -1 (no consumer has claimed yet)
    # And a successor segment linked via seg.next with:
    #   * cells[0] = (seq=1, value=99)
    #   * tail = 1
    #
    # Pre-fix behavior: first pop enters fast-path, mySlot=0,
    # prevConsumerIdx.CAS(-1, 0) succeeds, tryClaim returns none,
    # recheck shows CLOSED_BIT → segment retired, seg = nextSeg.
    # Subsequent pops drain nextSeg. Values 42, 43, 44 in the
    # retired seg are LOST.
    #
    # Post-fix behavior: pop returns some(42), some(43), some(44),
    # then some(99), then none(int) — no data loss.

    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, S, 4](addr manager)
    let segPtr = cast[SegPtr](queue.headSegmentForTest())
    check segPtr != nil

    # Force allocation of a second segment by pushing into the
    # queue past S items, then resetting.
    block: # use a separate scope to set up the linked successor
      var producer = queue.getProducerHere()
      for i in 0 ..< S + 1:
        producer.push(1000 + i) # fills seg0 then seg1

    # At this point headSegment may have been retired/advanced by
    # internal consumer state — but no consumer ran. headSegment
    # is still seg0. Drain it to a clean state via pop, then
    # manually craft the desired state.
    var consumer = queue.getConsumerHere()
    while consumer.pop().isSome:
      discard

    # After full drain, headSegment may be seg1 (if S+1 pushes
    # forced retirement on the last pop) or seg0 (if not). We
    # don't rely on that; instead we reset state on the CURRENT
    # head segment and ensure it has a non-nil successor.
    let curSegPtr = cast[SegPtr](queue.headSegmentForTest())
    check curSegPtr != nil

    # Reset cells, tail, prevConsumerIdx to the crafted scenario.
    curSegPtr.prevConsumerIdx.store(-1, moRelaxed)
    # cells[0] = CLOSED_BIT (close sentinel, empty payload)
    store(curSegPtr.cells[0], Pair[uint, int](first: CLOSED_BIT, second: 0), moRelaxed)
    # cells[1..3] = published values 42, 43, 44
    store(curSegPtr.cells[1], Pair[uint, int](first: 1'u, second: 42), moRelaxed)
    store(curSegPtr.cells[2], Pair[uint, int](first: 1'u, second: 43), moRelaxed)
    store(curSegPtr.cells[3], Pair[uint, int](first: 1'u, second: 44), moRelaxed)
    # cells[4..7] = empty
    for i in 4 ..< S:
      store(curSegPtr.cells[i], Pair[uint, int](first: 0'u, second: 0), moRelaxed)
    # tail = 4 (slots 0..3 reserved by producers)
    curSegPtr.tail.store(4, moRelaxed)

    # Ensure a successor segment is linked. If next is nil, we
    # allocate one by pushing past S more items.
    if curSegPtr.next.load(moRelaxed) == nil:
      # The current curSegPtr has tail=4; pushing more would fill
      # cells[4..7] then trigger nextSeg alloc on push #5. But
      # cells[4..7] are zero, so producer would write into them.
      # To keep our crafted state intact, push S-4+1 = 5 items;
      # producer writes 4..7 then allocates next-seg and writes
      # there. We'll then re-overwrite 4..7 to empty.
      var p2 = queue.getProducerHere()
      for i in 0 ..< (S - 4) + 1:
        p2.push(2000 + i)
      # Reset slots 4..7 to empty again so the crafted scenario
      # holds.
      for i in 4 ..< S:
        store(curSegPtr.cells[i], Pair[uint, int](first: 0'u, second: 0), moRelaxed)
      # And ensure tail is 4 (the producer may have advanced it).
      curSegPtr.tail.store(4, moRelaxed)
      # Reset prevConsumerIdx since the next-seg producer didn't
      # touch it but we want a clean state.
      curSegPtr.prevConsumerIdx.store(-1, moRelaxed)

    # Successor segment must be non-nil now.
    let nextSegRaw = curSegPtr.next.load(moRelaxed)
    check nextSegRaw != nil
    let nextSegPtr = cast[SegPtr](nextSegRaw)
    # Reset successor to a known state: single value at slot 0.
    nextSegPtr.prevConsumerIdx.store(-1, moRelaxed)
    store(nextSegPtr.cells[0], Pair[uint, int](first: 1'u, second: 99), moRelaxed)
    for i in 1 ..< S:
      store(nextSegPtr.cells[i], Pair[uint, int](first: 0'u, second: 0), moRelaxed)
    nextSegPtr.tail.store(1, moRelaxed)

    # Now run 5 pops. Pre-fix expects: some(99), then none x4
    # (because retiring head loses slots 1..3 = 42,43,44).
    # Post-fix expects: some(42), some(43), some(44), some(99),
    # then none.
    let r1 = consumer.pop()
    let r2 = consumer.pop()
    let r3 = consumer.pop()
    let r4 = consumer.pop()
    let r5 = consumer.pop()

    # Strongest assertion: full sequence then queue empty.
    check r1 == some(42)
    check r2 == some(43)
    check r3 == some(44)
    check r4 == some(99)
    check r5.isNone
