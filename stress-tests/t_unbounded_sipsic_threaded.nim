## Stress tests for UnboundedSipsic (SPSC linked-segment queue).
##
## R7 mandatory assertions (per design §3 Item 7):
##   (a) Total ``pushed == popped`` — global atomic counters.
##   (b) Per-item content equality — items encode (producerId shl 32 | seq)
##       so the consumer can verify exact provenance + value.
##   (c) FIFO-per-producer ordering — consumer maintains lastSeen[producerId]
##       and asserts strict monotonic increase within each producer's stream.
##
## Topology: 1p1c (SPSC). Item type: int (8 bytes on 64-bit; carries
## a 32-bit producerId in the high half and a 32-bit seq in the low half).

import options
import unittest2

import std/os
import std/strutils
import std/times

import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_sipsic


const
  ItemsPerProducer = 10000
  ProducerCount = 1
  ConsumerCount = 1
  ItemCount = ItemsPerProducer * ProducerCount


# LFQ_STRESS_DURATION_SEC: when set to a positive integer, the test loops
# its workload until wall-clock time exceeds the budget. When unset (or 0),
# behavior is unchanged: a single workload pass per test. See bounded
# reference at ``stress-tests/t_mupmuc_threaded.nim:23``.
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
  TestContext[S: static int] = object
    queue: ptr UnboundedSipsic[S, int]
    pushedTotal: ptr Atomic[int]
    poppedTotal: ptr Atomic[int]
    producerDone: ptr Atomic[bool]
    fifoViolation: ptr Atomic[bool]
    contentMismatch: ptr Atomic[bool]


proc producer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  for seq in 1 .. ItemsPerProducer:
    ctx.queue[].push(encodeItem(0, seq))
    discard ctx.pushedTotal[].fetchAdd(1, moRelaxed)
  ctx.producerDone[].store(true, moRelease)


proc consumer[S: static int](ctx: ptr TestContext[S]) {.thread.} =
  # Per-producer last-seen seq for FIFO-per-producer (R7c). For SPSC
  # there is exactly one producer (id 0) but the array shape mirrors
  # the multi-producer variants so the assertion mechanism is uniform.
  var lastSeen: array[ProducerCount, int]
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let v = item.get
      let pid = decodeProducerId(v)
      let s = decodeSeq(v)
      # (b) Content equality: producerId must match the only producer (0)
      # and seq must lie within the per-producer range.
      if pid < 0 or pid >= ProducerCount or s < 1 or s > ItemsPerProducer:
        ctx.contentMismatch[].store(true, moRelaxed)
      else:
        # (c) FIFO-per-producer: each pop within a producer's sub-stream
        # must have a strictly greater seq than the prior pop.
        if s <= lastSeen[pid]:
          ctx.fifoViolation[].store(true, moRelaxed)
        lastSeen[pid] = s
      discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      # Producer fully done. The acquire fence on `producerDone` makes
      # all of producer's release-stores (every `tail.store` and every
      # `next.store`) visible. If a final drain pop still returns None,
      # the queue is genuinely empty: surface the (a) count assertion
      # failure rather than livelock here.
      let drained = ctx.queue[].pop()
      if drained.isSome:
        let v = drained.get
        let pid = decodeProducerId(v)
        let s = decodeSeq(v)
        if pid < 0 or pid >= ProducerCount or s < 1 or s > ItemsPerProducer:
          ctx.contentMismatch[].store(true, moRelaxed)
        else:
          if s <= lastSeen[pid]:
            ctx.fifoViolation[].store(true, moRelaxed)
          lastSeen[pid] = s
        discard ctx.poppedTotal[].fetchAdd(1, moRelaxed)
        inc consumed
      else:
        break


suite "UnboundedSipsic threaded (R7)":

  var
    pushedTotal: Atomic[int]
    poppedTotal: Atomic[int]
    producerDone: Atomic[bool]
    fifoViolation: Atomic[bool]
    contentMismatch: Atomic[bool]

  proc resetState() =
    pushedTotal.store(0, moRelaxed)
    poppedTotal.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)
    fifoViolation.store(false, moRelaxed)
    contentMismatch.store(false, moRelaxed)

  setup:
    resetState()

  test "high segment turnover":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = newUnboundedSipsic[8, int]()

      var ctx = TestContext[8](
        queue: addr queue,
        pushedTotal: addr pushedTotal,
        poppedTotal: addr poppedTotal,
        producerDone: addr producerDone,
        fifoViolation: addr fifoViolation,
        contentMismatch: addr contentMismatch,
      )

      var prodThread, consThread: Thread[ptr TestContext[8]]
      createThread(prodThread, producer[8], addr ctx)
      createThread(consThread, consumer[8], addr ctx)
      joinThread(prodThread)
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
      var queue = newUnboundedSipsic[64, int]()

      var ctx = TestContext[64](
        queue: addr queue,
        pushedTotal: addr pushedTotal,
        poppedTotal: addr poppedTotal,
        producerDone: addr producerDone,
        fifoViolation: addr fifoViolation,
        contentMismatch: addr contentMismatch,
      )

      var prodThread, consThread: Thread[ptr TestContext[64]]
      createThread(prodThread, producer[64], addr ctx)
      createThread(consThread, consumer[64], addr ctx)
      joinThread(prodThread)
      joinThread(consThread)

      check(pushedTotal.load(moRelaxed) == ItemCount)
      check(poppedTotal.load(moRelaxed) == ItemCount)
      check(not contentMismatch.load(moRelaxed))
      check(not fifoViolation.load(moRelaxed))
      inc iter
