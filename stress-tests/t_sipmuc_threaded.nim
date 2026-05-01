import options
import unittest2

import std/os
import std/strutils
import std/times

import lockfreequeues
import lockfreequeues/backoff


const
  ItemCount = 10000
  ConsumerCount = 4


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
    queue: ptr Sipmuc[N, ConsumerCount, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]


proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  for i in 1..ItemCount:
    while not ctx.queue[].push(i):
      backoffOnPeerWait()
  ctx.producerDone[].store(true, moRelease)


proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
        break
    elif ctx.producerDone[].load(moAcquire):
      if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
        break


suite "Sipmuc threaded":

  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]
    totalConsumed: Atomic[int]

  proc resetState() =
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

  setup:
    resetState()

  test "high contention":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initSipmuc[16, ConsumerCount, int]()
      var ctx = TestContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone,
        totalConsumed: addr totalConsumed
      )

      var prodThread: Thread[ptr TestContext[16]]
      var consThreads: array[ConsumerCount, Thread[ptr TestContext[16]]]

      createThread(prodThread, producer[16], addr ctx)
      for i in 0..<ConsumerCount:
        createThread(consThreads[i], consumer[16], addr ctx)

      joinThread(prodThread)
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
      var queue = initSipmuc[64, ConsumerCount, int]()
      var ctx = TestContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone,
        totalConsumed: addr totalConsumed
      )

      var prodThread: Thread[ptr TestContext[64]]
      var consThreads: array[ConsumerCount, Thread[ptr TestContext[64]]]

      createThread(prodThread, producer[64], addr ctx)
      for i in 0..<ConsumerCount:
        createThread(consThreads[i], consumer[64], addr ctx)

      joinThread(prodThread)
      for i in 0..<ConsumerCount:
        joinThread(consThreads[i])

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter
