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
  TestContext[N: static int] = object
    queue: ptr Mupsic[N, ProducerCount, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    producerIdx: int


proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1..ItemsPerProducer:
    while not p.push(base + i):
      backoffOnPeerWait()
  discard ctx.producersDone[].fetchAdd(1, moRelease)


proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      # All producers done but we haven't consumed everything - keep trying
      discard


suite "Mupsic threaded":

  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]

  proc resetState() =
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)

  setup:
    resetState()

  test "high contention":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initMupsic[16, ProducerCount, int]()

      var contexts: array[ProducerCount, TestContext[16]]
      for i in 0..<ProducerCount:
        contexts[i] = TestContext[16](
          queue: addr queue,
          received: addr received,
          duplicateFound: addr duplicateFound,
          producersDone: addr producersDone,
          producerIdx: i
        )

      var consCtx = TestContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: 0
      )

      var prodThreads: array[ProducerCount, Thread[ptr TestContext[16]]]
      var consThread: Thread[ptr TestContext[16]]

      for i in 0..<ProducerCount:
        createThread(prodThreads[i], producer[16], addr contexts[i])
      createThread(consThread, consumer[16], addr consCtx)

      for i in 0..<ProducerCount:
        joinThread(prodThreads[i])
      joinThread(consThread)

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter

  test "normal capacity":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initMupsic[64, ProducerCount, int]()

      var contexts: array[ProducerCount, TestContext[64]]
      for i in 0..<ProducerCount:
        contexts[i] = TestContext[64](
          queue: addr queue,
          received: addr received,
          duplicateFound: addr duplicateFound,
          producersDone: addr producersDone,
          producerIdx: i
        )

      var consCtx = TestContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: 0
      )

      var prodThreads: array[ProducerCount, Thread[ptr TestContext[64]]]
      var consThread: Thread[ptr TestContext[64]]

      for i in 0..<ProducerCount:
        createThread(prodThreads[i], producer[64], addr contexts[i])
      createThread(consThread, consumer[64], addr consCtx)

      for i in 0..<ProducerCount:
        joinThread(prodThreads[i])
      joinThread(consThread)

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter
