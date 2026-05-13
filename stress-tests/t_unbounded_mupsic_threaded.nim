## Stress tests for UnboundedMupsic (MPSC linked-segment queue).
##
## R7 mandatory assertions (per design §3 Item 7):
##   (a) Total ``pushed == popped`` — global atomic counters.
##   (b) Per-item content equality — items encode (producerId shl 32 | seq)
##       so the consumer can verify exact provenance + value.
##   (c) FIFO-per-producer ordering — consumer maintains lastSeen[producerId]
##       and asserts strict monotonic increase within each producer's stream.
##
## Topology: 4p1c (MPSC). Item type: int (8 bytes on 64-bit; carries
## a 32-bit producerId in the high half and a 32-bit seq in the low half).
##
## API: v4.3 facade. ``newUnboundedMupsic[S, int, MaxThreads](addr manager,
## consumerHandle)`` is 3-param (uses DebraManager). ``withPin:`` is
## internal to the facade — test code calls ``p.push`` / ``queue.pop``
## directly and pinning is handled per-operation.

import options
import unittest2

import std/os
import std/strutils
import std/times

import debra
import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_mupsic


const
  ItemsPerProducer = 2500
  ProducerCount = 4
  ConsumerCount = 1
  MaxThreads = 8
  ItemCount = ItemsPerProducer * ProducerCount


# LFQ_STRESS_DURATION_SEC: when set to a positive integer, the test loops
# its workload until wall-clock time exceeds the budget. When unset (or 0),
# behavior is unchanged: a single workload pass per test.
let durSec = parseInt(getEnv("LFQ_STRESS_DURATION_SEC", "0"))
let deadline = if durSec > 0: epochTime() + durSec.float else: 0.0
proc shouldContinue(): bool =
  if durSec == 0: false
  else: epochTime() < deadline


# Encode ``(producerId, seq)`` into a single int payload. producerId in
# the high 32 bits, seq in the low 32 bits. seq is 1-indexed so 0 cannot
# alias an uninitialised slot.
proc encodeItem(producerId: int, seq: int): int =
  result = ((producerId.uint64 shl 32) or seq.uint64).int

proc decodeProducerId(item: int): int =
  result = int((item.uint64 shr 32) and 0xFFFFFFFF'u64)

proc decodeSeq(item: int): int =
  result = int(item.uint64 and 0xFFFFFFFF'u64)


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
    contentMismatch: ptr Atomic[bool]


proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(handle)
    for seq in 1 .. ItemsPerProducer:
      p.push(encodeItem(ctx.producerIdx, seq))
      discard ctx.pushedTotal[].fetchAdd(1, moRelaxed)
    discard ctx.producersDone[].fetchAdd(1, moRelease)


proc consumer[S: static int](ctx: ptr ConsumerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    # Per-producer last-seen seq for FIFO-per-producer (R7c).
    var lastSeen: array[ProducerCount, int]
    var consumed = 0

    proc record(v: int) =
      let pid = decodeProducerId(v)
      let s = decodeSeq(v)
      # (b) Content equality: producerId must lie in [0, ProducerCount)
      # and seq must lie in (0, ItemsPerProducer].
      if pid < 0 or pid >= ProducerCount or s < 1 or s > ItemsPerProducer:
        ctx.contentMismatch[].store(true, moRelaxed)
      else:
        # (c) FIFO-per-producer: each pop within a producer's sub-stream
        # must have a strictly greater seq than the prior pop.
        if s <= lastSeen[pid]:
          ctx.fifoViolation[].store(true, moRelaxed)
        lastSeen[pid] = s

    while consumed < ItemCount:
      let item = ctx.queue[].pop()
      if item.isSome:
        record(item.get)
        discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
        inc consumed
        continue
      if ctx.producersDone[].load(moAcquire) < ProducerCount:
        continue
      # All producers done; final drain attempt. The acquire fence on
      # producersDone makes all producer release-stores visible.
      let drained = ctx.queue[].pop()
      if drained.isSome:
        record(drained.get)
        discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
        inc consumed
      else:
        break


suite "UnboundedMupsic threaded (R7)":

  var
    pushedTotal: Atomic[int]
    poppedTotal: Atomic[int]
    producersDone: Atomic[int]
    fifoViolation: Atomic[bool]
    contentMismatch: Atomic[bool]

  proc resetState() =
    pushedTotal.store(0, moRelaxed)
    poppedTotal.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)
    fifoViolation.store(false, moRelaxed)
    contentMismatch.store(false, moRelaxed)

  setup:
    resetState()

  test "high segment turnover":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
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
        contentMismatch: addr contentMismatch,
      )

      var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[8]]]
      var consThread: Thread[ptr ConsumerContext[8]]

      for i in 0 ..< ProducerCount:
        createThread(prodThreads[i], producer[8], addr prodContexts[i])
      createThread(consThread, consumer[8], addr consCtx)

      for i in 0 ..< ProducerCount:
        joinThread(prodThreads[i])
      joinThread(consThread)

      # R7 assertions
      check(pushedTotal.load(moRelaxed) == ItemCount)            # (a)
      check(poppedTotal.load(moRelaxed) == ItemCount)            # (a)
      check(not contentMismatch.load(moRelaxed))                  # (b)
      check(not fifoViolation.load(moRelaxed))                    # (c)
      inc iter

  test "normal segment size":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var manager = initDebraManager[MaxThreads]()
      let consumerHandle = registerThread(manager)
      var queue = newUnboundedMupsic[64, int, MaxThreads](addr manager, consumerHandle)

      var prodContexts: array[ProducerCount, ProducerContext[64]]
      for i in 0 ..< ProducerCount:
        prodContexts[i] = ProducerContext[64](
          queue: addr queue,
          manager: addr manager,
          pushedTotal: addr pushedTotal,
          producersDone: addr producersDone,
          producerIdx: i,
        )

      var consCtx = ConsumerContext[64](
        queue: addr queue,
        poppedTotal: addr poppedTotal,
        producersDone: addr producersDone,
        fifoViolation: addr fifoViolation,
        contentMismatch: addr contentMismatch,
      )

      var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[64]]]
      var consThread: Thread[ptr ConsumerContext[64]]

      for i in 0 ..< ProducerCount:
        createThread(prodThreads[i], producer[64], addr prodContexts[i])
      createThread(consThread, consumer[64], addr consCtx)

      for i in 0 ..< ProducerCount:
        joinThread(prodThreads[i])
      joinThread(consThread)

      check(pushedTotal.load(moRelaxed) == ItemCount)
      check(poppedTotal.load(moRelaxed) == ItemCount)
      check(not contentMismatch.load(moRelaxed))
      check(not fifoViolation.load(moRelaxed))
      inc iter
