## T9 — MPMC push close-CAS-on-empty arbitration regression guard.
##
## Background
## ----------
## Phase B T8 wired the consumer pop slow-path to call
## `tryCloseOnEmpty(seg.cells[mySlot], 0)` on empty cells past
## `prevConsumerIdx+1` when `tail` has raced ahead. This closes the
## cell permanently (`seq=CLOSED_BIT`), preventing a stalled
## producer from later publishing into it and stranding the
## consumer.
##
## T8 introduces a new race: between the producer's successful
## `seg.tail.compareExchange(tail, tail+1, ...)` tail reservation
## and its subsequent `tryPublish(seg.cells[tail], 0, item)` DWCAS,
## a peer consumer may observe `mySlot < tail` with the cell still
## empty and CAS in `CLOSED_BIT`. The producer's `tryPublish` then
## fails because the cell no longer holds `seq=0`.
##
## Per design §4.2 + §6.4, the producer MUST escalate to the next
## segment on this failure (allocating if `seg.next == nil`), NOT
## retry within the same segment. The pre-T9 implementation
## `continue`d the outer loop, which would re-load `seg.tail`
## (advanced by peers) and try a different slot in the SAME
## segment — silently dropping the item the producer was about
## to publish (the tail reservation stands, no other producer
## targets it).
##
## Fix (T9)
## --------
## On `tryPublish` failure, the producer re-loads the cell:
##   * if `CLOSED_BIT` set — escalate to `seg.next` (allocate +
##     link if nil), advance `tailSegment`, `seg = nextSeg`,
##     continue outer loop.
##   * if not closed — fall through to existing outer-loop retry
##     (cell-CAS failure without close should not happen given
##     tail-CAS reservation discipline; defensive).
##
## Test strategy
## -------------
## The race window is bounded by the producer's instruction gap
## between its `tail`-CAS and its cell-publish DWCAS — small on
## modern hardware. A high-iteration stress soak with small
## segments and many aggressive consumers amplifies the window;
## consumers driving slow-path closes (T8) on cells the producer
## hasn't yet published to is exactly the trigger.
##
## The test pushes `TotalItems` integers from `ProducerCount`
## producer threads, pops them from `ConsumerCount` consumer
## threads (consumer-heavy ratio to maximise close-on-empty
## pressure), and verifies:
##   * exact `TotalItems` items consumed (no drops);
##   * no duplicates (no double-consume);
##   * sum of consumed values equals the arithmetic sum 1..N.
## Small `SegmentSize` forces frequent segment turnover, which
## also tests the alloc-and-link escalation path.
##
## Note on pre-fix detectability
## -----------------------------
## Like t_lcrq_pop_race, on the operator's M-series macOS dev box
## the producer-publish gap is small enough that this test may
## pass even on a pre-T9 implementation under typical scheduling.
## The test serves as a forward-looking regression guard against
## removal of the close-CAS-on-empty escalation, and amplifies the
## window enough to expose the bug on slower / contended hardware
## (CI, emulators, loaded systems).

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
  ProducerCount = 2
  ConsumerCount = 10 # consumer-heavy → maximise close-on-empty pressure
  ItemsPerProducer = TotalItems div ProducerCount
  MaxThreads = 32
  SegmentSize = 8 # small → high turnover, frequent escalation

type
  PCtx = object
    queue: ptr Queue[int, ccMulti, ccMulti, stEager, SegmentSize, MaxThreads]
    producersDone: ptr Atomic[int]
    producerIdx: int

  CCtx = object
    queue: ptr Queue[int, ccMulti, ccMulti, stEager, SegmentSize, MaxThreads]
    producersDone: ptr Atomic[int]
    consumedCount: ptr Atomic[int]
    consumedSum: ptr Atomic[int64]
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
        discard ctx.consumedSum[].fetchAdd(v.int64, moRelaxed)
        if ctx.consumedCount[].fetchAdd(1, moRelaxed) + 1 >= TotalItems:
          break
      elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
        # All producers done and the queue currently shows empty.
        # Always exit so missing items surface as a clean assertion
        # failure post-join rather than as a silent hang in the
        # consumer loop. consumedCount is asserted outside.
        break

suite "T9: MPMC push close-CAS-on-empty escalation — no drops, no duplicates":
  var
    producersDone: Atomic[int]
    consumedCount: Atomic[int]
    consumedSum: Atomic[int64]
    duplicateFound: Atomic[bool]
    received: array[TotalItems, Atomic[bool]]

  setup:
    producersDone.store(0, moRelaxed)
    consumedCount.store(0, moRelaxed)
    consumedSum.store(0'i64, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    for i in 0 ..< TotalItems:
      received[i].store(false, moRelaxed)

  test "producer escalates to nextSeg when consumer closes mid-publish":
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
    let expectedSum = (TotalItems.int64 * (TotalItems.int64 + 1)) div 2
    check(consumedCount.load(moRelaxed) == TotalItems)
    check(not duplicateFound.load(moRelaxed))
    check(consumedSum.load(moRelaxed) == expectedSum)
    for i in 0 ..< TotalItems:
      check(received[i].load(moRelaxed))
