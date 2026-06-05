## T6.C3 — MPMC pop case-(b) data-loss race regression guard.
##
## Background
## ----------
## After Phase B T6 wired `tryClaim(seg.cells[mySlot], expectedSeq=0)`
## into the MPMC pop fast path, the consumer claim path has two
## post-CAS branches when `tryClaim` returns `none`:
##   (a) cell observed with `CLOSED_BIT` set — close-on-empty raced
##       the producer; escalate to `nextSeg`.
##   (b) cell observed empty (seq == 0) — producer is mid-publish:
##       it has CAS'd `tail` forward but has not yet completed the
##       cell-publish DWCAS.
##
## The T6 implementation treated case (b) as `backoffOnRetry +
## continue` to the OUTER `while true` loop. That is incorrect: the
## consumer has already reserved `mySlot` via the successful
## `prevConsumerIdx.compareExchange(prevIdx, mySlot, ...)` CAS. When
## the outer loop re-enters, it reloads `prevConsumerIdx` (now equal
## to `mySlot`) and computes `mySlot' = prevIdx' + 1 = mySlot + 1`,
## advancing the consumer PAST the slot it reserved. When the
## delayed producer eventually publishes to the original `mySlot`,
## no consumer is targeting it; the value is orphaned (effectively
## dropped from the queue).
##
## Fix
## ---
## The post-T6 patch replaces the case-(b) `backoff + continue` with
## an INNER spin loop on the same `mySlot`. The consumer that
## reserved the slot owns it until either:
##   * the producer publishes (seq becomes 1) — claim and return; or
##   * the cell transitions to CLOSED — escalate to `nextSeg`.
## `mySlot` is held FIXED across the inner loop; the consumer never
## advances past its reservation.
##
## Test strategy
## -------------
## The race window is bounded by the producer's instruction gap
## between its `tail`-CAS and its cell-publish DWCAS, which is small
## (a handful of instructions on modern hardware). A single-shot
## deterministic repro would require a test-only hook in the
## producer fast path; that intrusion is not warranted given that
## a high-iteration stress soak with small segments amplifies the
## window enough to expose the bug pre-fix on typical hardware.
##
## The test pushes `TotalItems` integers from `ProducerCount`
## producer threads, pops them from `ConsumerCount` consumer
## threads, and verifies:
##   * exact `TotalItems` items consumed (no drops, no orphaning);
##   * no duplicates (no double-consume);
##   * sum of consumed values equals the expected arithmetic sum.
## Small `SegmentSize` forces frequent segment turnover, which
## maximises contention on `prevConsumerIdx` and amplifies the
## case-(b) window.
##
## Note on pre-fix detectability
## -----------------------------
## On the operator's M-series macOS dev box, the pre-fix T6
## implementation passed `t_unbounded_mpmc_threaded` 4/4 because
## typical scheduling lets the producer's `tryPublish` complete
## before the consumer's next loop iteration. This stress test runs
## at 10x the item count and 2x the consumer count of the standard
## threaded suite specifically to expose tail-of-distribution
## scheduling on machines where the gap widens (loaded systems,
## emulators, slower cores). On hardware where the race never fires
## pre-fix, this test serves as a forward-looking regression guard
## against re-introduction of the case-(b) `continue` pattern.

import debra/atomics
import debra/atomics/dsl
import options
import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

from debra import DebraManager, registerThread
import ./debra_cc_helpers

const
  TotalItems = 100_000
  ProducerCount = 4
  ConsumerCount = 8
  ItemsPerProducer = TotalItems div ProducerCount
  MaxThreads = 32
  SegmentSize = 8 # small → high turnover → max prevConsumerIdx contention

type
  PCtx = object
    queue: ptr Queue[int, ccMulti, ccMulti, stEager, SegmentSize, MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  CCtx = object
    queue: ptr Queue[int, ccMulti, ccMulti, stEager, SegmentSize, MaxThreads]
    producersDone: ptr Atomic[int]
    consumedCount: ptr Atomic[int]
    consumedSum: ptr Atomic[int]
    duplicateFound: ptr Atomic[bool]
    received: ptr array[TotalItems, Atomic[bool]]

proc producerProc(ctx: ptr PCtx) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducerHere()
    let base = ctx.producerIdx * ItemsPerProducer
    for i in 1 .. ItemsPerProducer:
      p.push(base + i)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumerProc(ctx: ptr CCtx) {.thread.} =
  {.cast(gcsafe).}:
    var c = ctx.queue[].getConsumerHere()
    while true:
      let item = c.pop()
      if item.isSome:
        let v = item.get
        let idx = v - 1 # values are 1..TotalItems (1-indexed)
        if ctx.received[idx].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        discard ctx.consumedSum[].fetchAdd(v, moRelaxed)
        if ctx.consumedCount[].fetchAdd(1, moRelaxed) + 1 >= TotalItems:
          break
      elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
        if ctx.consumedCount[].load(moRelaxed) >= TotalItems:
          break

suite "T6.C3: MPMC pop case-(b) race — no orphaned values under stress":
  var
    producersDone: Atomic[int]
    consumedCount: Atomic[int]
    consumedSum: Atomic[int]
    duplicateFound: Atomic[bool]
    received: array[TotalItems, Atomic[bool]]

  setup:
    producersDone.store(0, moRelaxed)
    consumedCount.store(0, moRelaxed)
    consumedSum.store(0, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    for i in 0 ..< TotalItems:
      received[i].store(false, moRelaxed)

  test "case-(b) reservation is respected — no drops, no duplicates":
    var manager = initMultiConsumerManager[MaxThreads]()
    var queue =
      newUnboundedMpmcQueue[int, stEager, SegmentSize, MaxThreads](addr manager)

    var pctxs: array[ProducerCount, PCtx]
    for i in 0 ..< ProducerCount:
      pctxs[i] =
        PCtx(queue: addr queue, producersDone: addr producersDone, producerIdx: i)

    var cctxs: array[ConsumerCount, CCtx]
    for i in 0 ..< ConsumerCount:
      cctxs[i] = CCtx(
        queue: addr queue,
        producersDone: addr producersDone,
        consumedCount: addr consumedCount,
        consumedSum: addr consumedSum,
        duplicateFound: addr duplicateFound,
        received: addr received,
      )

    var pThreads: array[ProducerCount, Thread[ptr PCtx]]
    var cThreads: array[ConsumerCount, Thread[ptr CCtx]]

    for i in 0 ..< ProducerCount:
      createThread(pThreads[i], producerProc, addr pctxs[i])
    for i in 0 ..< ConsumerCount:
      createThread(cThreads[i], consumerProc, addr cctxs[i])

    for i in 0 ..< ProducerCount:
      joinThread(pThreads[i])
    for i in 0 ..< ConsumerCount:
      joinThread(cThreads[i])

    # Expected: sum of 1..TotalItems = TotalItems * (TotalItems + 1) / 2.
    # Use int64 arithmetic for the expected to avoid overflow at large
    # TotalItems even though on 64-bit `int` is wide enough.
    let expectedSum = (TotalItems.int64 * (TotalItems.int64 + 1)) div 2
    check(consumedCount.load(moRelaxed) == TotalItems)
    check(not duplicateFound.load(moRelaxed))
    check(consumedSum.load(moRelaxed).int64 == expectedSum)
    # Every value [1..TotalItems] must have been consumed exactly once.
    for i in 0 ..< TotalItems:
      check(received[i].load(moRelaxed))
