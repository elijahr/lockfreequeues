## R7 regression test for unbounded sipsic (SPSC) — guards against the
## TOCTOU item-loss livelock fixed by F1 + F1' in
## `typestates/unbounded_spsc_pop.nim`. Asserts pushed == popped count
## under high segment turnover (S=8). Pre-fix this would FAIL with
## drift -2..-8 / 10000 at ~40% rate; post-fix expects 100% green.

import lockfreequeues/atomic_dsl
import options
import unittest2

import lockfreequeues/unbounded_sipsic

const ItemCount = 10000

type TestContext[S: static int] = object
  queue: ptr UnboundedSipsic[S, int]
  pushedTotal: ptr Atomic[int]
  poppedTotal: ptr Atomic[int]
  producerDone: ptr Atomic[bool]
  fifoViolation: ptr Atomic[bool]

proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  for i in 1 .. ItemCount:
    ctx.queue[].push(i)
    discard ctx.pushedTotal[].fetchAdd(1, moRelaxed)
  ctx.producerDone[].store(true, moRelease)

proc consumer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  var lastSeen = 0
  while true:
    let item = ctx.queue[].pop()
    if item.isSome:
      let v = item.get
      if v <= lastSeen:
        ctx.fifoViolation[].store(true, moRelaxed)
      lastSeen = v
      discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
      continue
    if not ctx.producerDone[].load(moAcquire):
      continue
    # producerDone observed; final drain pop. Either still has items
    # (bug-suspected segments produce isSome here post-doneObserved) or
    # genuinely empty.
    let drained = ctx.queue[].pop()
    if drained.isSome:
      let v = drained.get
      if v <= lastSeen:
        ctx.fifoViolation[].store(true, moRelaxed)
      lastSeen = v
      discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
      continue
    break

suite "UnboundedSipsic R7 threaded count assertion":
  var
    pushedTotal: Atomic[int]
    poppedTotal: Atomic[int]
    producerDone: Atomic[bool]
    fifoViolation: Atomic[bool]

  setup:
    pushedTotal.store(0, moRelaxed)
    poppedTotal.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)
    fifoViolation.store(false, moRelaxed)

  test "S=8 high segment turnover, R7 count + FIFO":
    var queue = newUnboundedSipsic[8, int]()
    var ctx = TestContext[8](
      queue: addr queue,
      pushedTotal: addr pushedTotal,
      poppedTotal: addr poppedTotal,
      producerDone: addr producerDone,
      fifoViolation: addr fifoViolation,
    )

    var prodThread, consThread: Thread[ptr TestContext[8]]
    createThread(prodThread, producer[8], addr ctx)
    createThread(consThread, consumer[8], addr ctx)

    joinThread(prodThread)
    joinThread(consThread)

    check(pushedTotal.load(moRelaxed) == ItemCount)
    check(poppedTotal.load(moRelaxed) == ItemCount)
    check(not fifoViolation.load(moRelaxed))
