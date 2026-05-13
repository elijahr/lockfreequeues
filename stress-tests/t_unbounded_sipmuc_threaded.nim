## Stress tests for UnboundedSipmuc (SPMC linked-segment queue).
##
## R7 mandatory assertions (per design §3 Item 7):
##   (a) Total ``pushed == popped`` — global atomic counters.
##   (b) Per-item content equality — items encode (producerId shl 32 | seq)
##       so consumers can verify exact provenance + value. With a single
##       producer (id 0), this also catches duplicates: a per-(pid,seq)
##       seenSeq array detects any item returned twice across all consumers.
##   (c) FIFO-per-producer ordering — each consumer's local sub-stream
##       of pops, restricted to a single producer, must be strictly
##       monotonic in seq. SPMC fans the producer's sequence out across
##       consumers, so global-order FIFO across consumers is NOT a
##       correctness property; the per-consumer-per-producer monotonic
##       subsequence IS. Each consumer maintains a private
##       ``lastSeen[pid]`` and asserts strict increase locally.
##
## Topology: 1p4c (SPMC). Item type: int (8 bytes on 64-bit; carries
## a 32-bit producerId in the high half and a 32-bit seq in the low half).
##
## API: v4.3 facade. ``newUnboundedSipmuc[S, int, MaxThreads](addr manager)``
## is 3-param (uses DebraManager). Producer thread calls ``queue.push``
## directly (single-producer path needs no DEBRA registration in the
## current facade); consumers register and use ``c.pop()``.

import options
import unittest2

import std/os
import std/strutils
import std/times

import debra
import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_sipmuc


const
  ItemsPerProducer = 10000
  ProducerCount = 1
  ConsumerCount = 4
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
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    pushedTotal: ptr Atomic[int]
    producerDone: ptr Atomic[bool]

  ConsumerContext[S: static int] = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    poppedTotal: ptr Atomic[int]
    producerDone: ptr Atomic[bool]
    seenSeq: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    fifoViolation: ptr Atomic[bool]
    contentMismatch: ptr Atomic[bool]


proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    for seq in 1 .. ItemsPerProducer:
      ctx.queue[].push(encodeItem(0, seq))
      discard ctx.pushedTotal[].fetchAdd(1, moRelaxed)
    ctx.producerDone[].store(true, moRelease)


proc consumer[S: static int](ctx: ptr ConsumerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(handle)

    # Per-consumer-per-producer last-seen seq for FIFO-per-producer (R7c).
    # Each consumer's sub-stream restricted to a given producer must be
    # strictly monotonic in seq. SPMC scatters items across consumers, so
    # GLOBAL FIFO is not a correctness property — but THIS consumer's pop
    # order, filtered to producer pid, must respect the producer's push
    # order. (Producer pushes 1..N in order; any consumer's pops, in pop
    # order, are a strictly increasing subsequence of 1..N.)
    var lastSeen: array[ProducerCount, int]

    proc record(v: int) =
      let pid = decodeProducerId(v)
      let s = decodeSeq(v)
      # (b) Content equality: producerId must be 0 (single producer)
      # and seq must lie in (0, ItemsPerProducer].
      if pid < 0 or pid >= ProducerCount or s < 1 or s > ItemsPerProducer:
        ctx.contentMismatch[].store(true, moRelaxed)
        return
      # (b') Duplicate detection: each (producerId, seq) must be popped
      # exactly once across the entire SPMC fan-out.
      let flatIdx = pid * ItemsPerProducer + (s - 1)
      if ctx.seenSeq[flatIdx].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      # (c) FIFO-per-producer (per-consumer subsequence): each pop within
      # this consumer's sub-stream for producer pid must have a strictly
      # greater seq than the prior pop from the same producer.
      if s <= lastSeen[pid]:
        ctx.fifoViolation[].store(true, moRelaxed)
      lastSeen[pid] = s

    while true:
      let item = c.pop()
      if item.isSome:
        record(item.get)
        if ctx.poppedTotal[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
          break
      elif ctx.producerDone[].load(moAcquire):
        if ctx.poppedTotal[].load(moRelaxed) >= ItemCount:
          break


suite "UnboundedSipmuc threaded (R7)":

  var
    pushedTotal: Atomic[int]
    poppedTotal: Atomic[int]
    producerDone: Atomic[bool]
    fifoViolation: Atomic[bool]
    contentMismatch: Atomic[bool]
    duplicateFound: Atomic[bool]
    seenSeq: array[ItemCount, Atomic[bool]]

  proc resetState() =
    pushedTotal.store(0, moRelaxed)
    poppedTotal.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)
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
      var queue = newUnboundedSipmuc[8, int, MaxThreads](addr manager)

      var prodCtx = ProducerContext[8](
        queue: addr queue,
        pushedTotal: addr pushedTotal,
        producerDone: addr producerDone,
      )

      var consCtxs: array[ConsumerCount, ConsumerContext[8]]
      for i in 0 ..< ConsumerCount:
        consCtxs[i] = ConsumerContext[8](
          queue: addr queue,
          manager: addr manager,
          poppedTotal: addr poppedTotal,
          producerDone: addr producerDone,
          seenSeq: addr seenSeq,
          duplicateFound: addr duplicateFound,
          fifoViolation: addr fifoViolation,
          contentMismatch: addr contentMismatch,
        )

      var prodThread: Thread[ptr ProducerContext[8]]
      var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[8]]]

      createThread(prodThread, producer[8], addr prodCtx)
      for i in 0 ..< ConsumerCount:
        createThread(consThreads[i], consumer[8], addr consCtxs[i])

      joinThread(prodThread)
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
      var queue = newUnboundedSipmuc[64, int, MaxThreads](addr manager)

      var prodCtx = ProducerContext[64](
        queue: addr queue,
        pushedTotal: addr pushedTotal,
        producerDone: addr producerDone,
      )

      var consCtxs: array[ConsumerCount, ConsumerContext[64]]
      for i in 0 ..< ConsumerCount:
        consCtxs[i] = ConsumerContext[64](
          queue: addr queue,
          manager: addr manager,
          poppedTotal: addr poppedTotal,
          producerDone: addr producerDone,
          seenSeq: addr seenSeq,
          duplicateFound: addr duplicateFound,
          fifoViolation: addr fifoViolation,
          contentMismatch: addr contentMismatch,
        )

      var prodThread: Thread[ptr ProducerContext[64]]
      var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[64]]]

      createThread(prodThread, producer[64], addr prodCtx)
      for i in 0 ..< ConsumerCount:
        createThread(consThreads[i], consumer[64], addr consCtxs[i])

      joinThread(prodThread)
      for i in 0 ..< ConsumerCount:
        joinThread(consThreads[i])

      check(pushedTotal.load(moRelaxed) == ItemCount)
      check(poppedTotal.load(moRelaxed) == ItemCount)
      check(not contentMismatch.load(moRelaxed))
      check(not duplicateFound.load(moRelaxed))
      check(not fifoViolation.load(moRelaxed))
      inc iter
