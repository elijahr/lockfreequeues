import options
import unittest2

import std/os
import std/strutils
import std/times

import lockfreequeues
import lockfreequeues/backoff


const
  ItemCount = 10000
  ProducerCount = 4
  ConsumerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount


# LFQ_STRESS_DURATION_SEC: when set to a positive integer, each test loops
# its workload until wall-clock time exceeds the budget. When unset (or 0),
# behavior is unchanged: a single workload pass per test. See design doc
# §10.16a (TSAN duration harness, I6).
let durSec = parseInt(getEnv("LFQ_STRESS_DURATION_SEC", "0"))
let deadline = if durSec > 0: epochTime() + durSec.float else: 0.0
proc shouldContinue(): bool =
  if durSec == 0: false
  else: epochTime() < deadline


type
  ProducerContext[N: static int] = object
    queue: ptr Mupmuc[N, ProducerCount, ConsumerCount, int]
    producersDone: ptr Atomic[int]
    producerIdx: int

  ConsumerContext[N: static int] = object
    queue: ptr Mupmuc[N, ProducerCount, ConsumerCount, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]


proc producer[N: static int](ctx: ptr ProducerContext[N]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1..ItemsPerProducer:
    while not p.push(base + i):
      backoffOnPeerWait()
  discard ctx.producersDone[].fetchAdd(1, moRelease)


proc consumer[N: static int](ctx: ptr ConsumerContext[N]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
        break
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
        break


suite "Mupmuc threaded":

  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]
    totalConsumed: Atomic[int]

  proc resetState() =
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)

  setup:
    resetState()

  test "high contention":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initMupmuc[16, ProducerCount, ConsumerCount, int]()

      var prodContexts: array[ProducerCount, ProducerContext[16]]
      for i in 0..<ProducerCount:
        prodContexts[i] = ProducerContext[16](
          queue: addr queue,
          producersDone: addr producersDone,
          producerIdx: i
        )

      var consContexts: array[ConsumerCount, ConsumerContext[16]]
      for i in 0..<ConsumerCount:
        consContexts[i] = ConsumerContext[16](
          queue: addr queue,
          received: addr received,
          duplicateFound: addr duplicateFound,
          producersDone: addr producersDone,
          totalConsumed: addr totalConsumed
        )

      var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[16]]]
      var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[16]]]

      for i in 0..<ProducerCount:
        createThread(prodThreads[i], producer[16], addr prodContexts[i])
      for i in 0..<ConsumerCount:
        createThread(consThreads[i], consumer[16], addr consContexts[i])

      for i in 0..<ProducerCount:
        joinThread(prodThreads[i])
      for i in 0..<ConsumerCount:
        joinThread(consThreads[i])

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter

  test "normal capacity":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initMupmuc[64, ProducerCount, ConsumerCount, int]()

      var prodContexts: array[ProducerCount, ProducerContext[64]]
      for i in 0..<ProducerCount:
        prodContexts[i] = ProducerContext[64](
          queue: addr queue,
          producersDone: addr producersDone,
          producerIdx: i
        )

      var consContexts: array[ConsumerCount, ConsumerContext[64]]
      for i in 0..<ConsumerCount:
        consContexts[i] = ConsumerContext[64](
          queue: addr queue,
          received: addr received,
          duplicateFound: addr duplicateFound,
          producersDone: addr producersDone,
          totalConsumed: addr totalConsumed
        )

      var prodThreads: array[ProducerCount, Thread[ptr ProducerContext[64]]]
      var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[64]]]

      for i in 0..<ProducerCount:
        createThread(prodThreads[i], producer[64], addr prodContexts[i])
      for i in 0..<ConsumerCount:
        createThread(consThreads[i], consumer[64], addr consContexts[i])

      for i in 0..<ProducerCount:
        joinThread(prodThreads[i])
      for i in 0..<ConsumerCount:
        joinThread(consThreads[i])

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter
