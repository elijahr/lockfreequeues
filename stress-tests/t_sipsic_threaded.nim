import options
import unittest2

import std/os
import std/strutils
import std/times

import lockfreequeues
import lockfreequeues/backoff


const ItemCount = 10000


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
    queue: ptr Sipsic[N, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]


proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  for i in 1..ItemCount:
    while not ctx.queue[].push(i):
      backoffOnPeerWait()
  ctx.producerDone[].store(true, moRelease)


proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1  # Items are 1-indexed
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      # Producer done but we haven't consumed everything - keep trying
      discard


suite "Sipsic threaded":

  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]

  proc resetState() =
    for i in 0..<ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)

  setup:
    resetState()

  test "high contention":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initSipsic[16, int]()
      var ctx = TestContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone
      )

      var prodThread, consThread: Thread[ptr TestContext[16]]
      createThread(prodThread, producer[16], addr ctx)
      createThread(consThread, consumer[16], addr ctx)

      joinThread(prodThread)
      joinThread(consThread)

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter

  test "normal capacity":
    var iter = 0
    while iter == 0 or shouldContinue():
      if iter > 0: resetState()
      var queue = initSipsic[64, int]()
      var ctx = TestContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producerDone: addr producerDone
      )

      var prodThread, consThread: Thread[ptr TestContext[64]]
      createThread(prodThread, producer[64], addr ctx)
      createThread(consThread, consumer[64], addr ctx)

      joinThread(prodThread)
      joinThread(consThread)

      check(not duplicateFound.load(moRelaxed))
      for i in 0..<ItemCount:
        check(received[i].load(moRelaxed))
      inc iter
