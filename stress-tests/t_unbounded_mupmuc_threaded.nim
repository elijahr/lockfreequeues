## Stress tests for UnboundedMupmuc (MPMC linked-segment queue).
##
## R7 mandatory assertions (per design §3 Item 7):
##   (a) Total ``pushed == popped`` — global atomic counters.
##   (b) Per-item content equality — items encode (producerId shl 32 | seq)
##       so consumers can verify exact provenance + value. A per-(pid,seq)
##       seenSeq array detects any item returned twice across all consumers.
##   (c) FIFO-per-producer ordering — each consumer's local sub-stream of
##       pops, restricted to a single producer, must be strictly monotonic
##       in seq. MPMC fans each producer's sequence out across consumers,
##       so global-order FIFO across consumers is NOT a correctness
##       property; the per-consumer-per-producer monotonic subsequence IS.
##
## Topology: 2p2c (MPMC). Item type: int (8 bytes on 64-bit; carries
## a 32-bit producerId in the high half and a 32-bit seq in the low half).
##
## API: v4.3 facade. ``newUnboundedMupmuc[S, int, MaxThreads](addr manager)``
## is 3-param (uses DebraManager). Producers and consumers each register a
## DEBRA handle and call ``p.push`` / ``c.pop`` directly.

import options
import unittest2

import std/os
import std/strutils
import std/times

import debra
import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_mupmuc


const
  ItemsPerProducer = 5000
  ProducerCount = 2
  ConsumerCount = 2
  MaxThreads = 16
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
    queue: ptr UnboundedMupmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    pushedTotal: ptr Atomic[int]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedMupmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    poppedTotal: ptr Atomic[int]
    producersDone: ptr Atomic[int]
    seenSeq: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
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
    let handle = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(handle)

    # Per-consumer-per-producer last-seen seq for FIFO-per-producer (R7c).
    # Each consumer's pops, filtered to a given producer, must be a
    # strictly increasing subsequence of that producer's push sequence.
    var lastSeen: array[ProducerCount, int]

    proc record(v: int) =
      let pid = decodeProducerId(v)
      let s = decodeSeq(v)
      # (b) Content equality: producerId must lie in [0, ProducerCount)
      # and seq must lie in (0, ItemsPerProducer].
      if pid < 0 or pid >= ProducerCount or s < 1 or s > ItemsPerProducer:
        ctx.contentMismatch[].store(true, moRelaxed)
        return
      # (b') Duplicate detection: each (producerId, seq) must be popped
      # exactly once across the entire MPMC fan-out.
      let flatIdx = pid * ItemsPerProducer + (s - 1)
      if ctx.seenSeq[flatIdx].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      # (c) FIFO-per-producer (per-consumer subsequence): each pop within
      # this consumer's sub-stream for producer pid must have a strictly
      # greater seq than the prior pop from the same producer on this
      # consumer.
      if s <= lastSeen[pid]:
        ctx.fifoViolation[].store(true, moRelaxed)
      lastSeen[pid] = s

    while true:
      let item = c.pop()
      if item.isSome:
        record(item.get)
        if ctx.poppedTotal[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
          break
      elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
        if ctx.poppedTotal[].load(moRelaxed) >= ItemCount:
          break


suite "UnboundedMupmuc threaded (R7)":

  var
    pushedTotal: Atomic[int]
    poppedTotal: Atomic[int]
    producersDone: Atomic[int]
    fifoViolation: Atomic[bool]
    contentMismatch: Atomic[bool]
    duplicateFound: Atomic[bool]
    seenSeq: array[ItemCount, Atomic[bool]]

  proc resetState() =
    pushedTotal.store(0, moRelaxed)
    poppedTotal.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)
    fifoViolation.store(false, moRelaxed)
    contentMismatch.store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    for i in 0 ..< ItemCount:
      seenSeq[i].store(false, moRelaxed)

  setup:
    resetState()

  test "high segment turnover":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var manager = initDebraManager[MaxThreads]()
      var queue = newUnboundedMupmuc[8, int, MaxThreads](addr manager)

      var prodContexts: array[ProducerCount, ProducerContext[8]]
      for i in 0 ..< ProducerCount:
        prodContexts[i] = ProducerContext[8](
          queue: addr queue,
          manager: addr manager,
          pushedTotal: addr pushedTotal,
          producersDone: addr producersDone,
          producerIdx: i,
        )

      var consContexts: array[ConsumerCount, ConsumerContext[8]]
      for i in 0 ..< ConsumerCount:
        consContexts[i] = ConsumerContext[8](
          queue: addr queue,
          manager: addr manager,
          poppedTotal: addr poppedTotal,
          producersDone: addr producersDone,
          seenSeq: addr seenSeq,
          duplicateFound: addr duplicateFound,
          fifoViolation: addr fifoViolation,
          contentMismatch: addr contentMismatch,
        )

      var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[8]]]
      var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[8]]]

      for i in 0 ..< ProducerCount:
        createThread(prodThreads[i], producer[8], addr prodContexts[i])
      for i in 0 ..< ConsumerCount:
        createThread(consThreads[i], consumer[8], addr consContexts[i])

      for i in 0 ..< ProducerCount:
        joinThread(prodThreads[i])
      for i in 0 ..< ConsumerCount:
        joinThread(consThreads[i])

      # R7 assertions
      check(pushedTotal.load(moRelaxed) == ItemCount)            # (a)
      check(poppedTotal.load(moRelaxed) == ItemCount)            # (a)
      check(not contentMismatch.load(moRelaxed))                  # (b)
      check(not duplicateFound.load(moRelaxed))                   # (b')
      check(not fifoViolation.load(moRelaxed))                    # (c)
      inc iter

  test "normal segment size":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var manager = initDebraManager[MaxThreads]()
      var queue = newUnboundedMupmuc[64, int, MaxThreads](addr manager)

      var prodContexts: array[ProducerCount, ProducerContext[64]]
      for i in 0 ..< ProducerCount:
        prodContexts[i] = ProducerContext[64](
          queue: addr queue,
          manager: addr manager,
          pushedTotal: addr pushedTotal,
          producersDone: addr producersDone,
          producerIdx: i,
        )

      var consContexts: array[ConsumerCount, ConsumerContext[64]]
      for i in 0 ..< ConsumerCount:
        consContexts[i] = ConsumerContext[64](
          queue: addr queue,
          manager: addr manager,
          poppedTotal: addr poppedTotal,
          producersDone: addr producersDone,
          seenSeq: addr seenSeq,
          duplicateFound: addr duplicateFound,
          fifoViolation: addr fifoViolation,
          contentMismatch: addr contentMismatch,
        )

      var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[64]]]
      var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[64]]]

      for i in 0 ..< ProducerCount:
        createThread(prodThreads[i], producer[64], addr prodContexts[i])
      for i in 0 ..< ConsumerCount:
        createThread(consThreads[i], consumer[64], addr consContexts[i])

      for i in 0 ..< ProducerCount:
        joinThread(prodThreads[i])
      for i in 0 ..< ConsumerCount:
        joinThread(consThreads[i])

      check(pushedTotal.load(moRelaxed) == ItemCount)
      check(poppedTotal.load(moRelaxed) == ItemCount)
      check(not contentMismatch.load(moRelaxed))
      check(not duplicateFound.load(moRelaxed))
      check(not fifoViolation.load(moRelaxed))
      inc iter
