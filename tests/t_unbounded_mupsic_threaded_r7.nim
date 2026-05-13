## R7 regression test for unbounded mupsic (MPSC) — guards against the
## TOCTOU item-loss livelock fixed by F1 + F1' in
## `typestates/unbounded_mpsc_pop.nim`. Asserts pushed == popped count
## and FIFO-per-producer under high segment turnover (S=8).

import lockfreequeues/atomic_dsl
import options
import unittest2

import debra
import lockfreequeues/unbounded_mupsic

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount
  MaxThreads = 8

type
  ProducerContext[S: static int] = object
    queue: ptr UnboundedMupsic[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    pushedTotal: ptr Atomic[int]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedMupsic[S, int, MaxThreads]
    poppedTotal: ptr Atomic[int]
    producersDone: ptr Atomic[int]
    fifoViolation: ptr Atomic[bool]

proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(handle)
    let base = ctx.producerIdx * ItemsPerProducer
    for i in 1 .. ItemsPerProducer:
      p.push(base + i)
      discard ctx.pushedTotal[].fetchAdd(1, moRelaxed)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[S: static int](ctx: ptr ConsumerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    var lastSeen: array[ProducerCount, int]
    proc record(v: int) =
      let producerIdx = (v - 1) div ItemsPerProducer
      if producerIdx >= 0 and producerIdx < ProducerCount:
        if v <= lastSeen[producerIdx]:
          ctx.fifoViolation[].store(true, moRelaxed)
        lastSeen[producerIdx] = v

    while true:
      let item = ctx.queue[].pop()
      if item.isSome:
        record(item.get)
        discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
        continue
      if ctx.producersDone[].load(moAcquire) < ProducerCount:
        continue
      # All producers done; final drain.
      let drained = ctx.queue[].pop()
      if drained.isSome:
        record(drained.get)
        discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
        continue
      break

suite "UnboundedMupsic R7 threaded count assertion":
  var
    pushedTotal: Atomic[int]
    poppedTotal: Atomic[int]
    producersDone: Atomic[int]
    fifoViolation: Atomic[bool]

  setup:
    pushedTotal.store(0, moRelaxed)
    poppedTotal.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)
    fifoViolation.store(false, moRelaxed)

  test "S=8 high segment turnover, R7 count + FIFO-per-producer":
    var manager = initDebraManager[MaxThreads]()
    let consumerHandle = registerThread(manager)
    var queue = newUnboundedMupsic[8, int, MaxThreads](addr manager, consumerHandle)

    var prodContexts: array[ProducerCount, ProducerContext[8]]
    for i in 0 ..< ProducerCount:
      prodContexts[i] = ProducerContext[8](
        queue: addr queue,
        manager: addr manager,
        pushedTotal: addr pushedTotal,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = ConsumerContext[8](
      queue: addr queue,
      poppedTotal: addr poppedTotal,
      producersDone: addr producersDone,
      fifoViolation: addr fifoViolation,
    )

    var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[8]]]
    var consThread: Thread[ptr ConsumerContext[8]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[8], addr prodContexts[i])
    createThread(consThread, consumer[8], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(pushedTotal.load(moRelaxed) == ItemCount)
    check(poppedTotal.load(moRelaxed) == ItemCount)
    check(not fifoViolation.load(moRelaxed))
