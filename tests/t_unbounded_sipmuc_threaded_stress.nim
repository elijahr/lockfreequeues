## Stress test for the unbounded SPMC queue's intermittent end-of-run
## livelock pattern. Gated by ``-d:stress`` so the default test run stays
## fast; CI / pre-release runs invoke this via ``nimble stresstest`` to
## hammer the regression surface 50 times per scenario.
##
## When compiled WITHOUT ``-d:stress``, every test compiles but reports
## ``0 OK, 0 SKIPPED`` — the body collapses into nothing. This keeps the
## file in the test set's link graph (so build-only CI catches type
## drift) while charging zero runtime cost.
##
## When compiled WITH ``-d:stress``, each test runs its scenario 50
## times in an outer loop, reset state between iterations.
##
## Optional diagnostic logging is gated by ``-d:stressDebug``: enables
## the per-thread heartbeat + 1000-item checkpoint logs that
## ``t_unbounded_sipmuc_threaded_diag.nim`` carried. The hang-debug
## tooling (``scripts/run_with_hang_sample.py``) uses the heartbeat
## output to localise where a stuck consumer is parked.

import lockfreequeues/atomic_dsl
import options
import unittest2

import debra
import lockfreequeues/unbounded_sipmuc

when defined(stressDebug):
  import os
  import times
  import locks

const
  ItemCount = 10000
  ConsumerCount = 4
  MaxThreads = 8
  StressIterations = 50
    ## Outer iteration count when ``-d:stress`` is set. Sized to make a
    ## 1/30-frequency intermittent regression near-certain to fire.

when defined(stressDebug):
  var logLock: Lock
  initLock(logLock)

  proc dlog(msg: string) =
    withLock(logLock):
      stderr.writeLine($epochTime() & " " & msg)
      stderr.flushFile()
else:
  template dlog(msg: string) =
    discard

type
  ProducerContext[S: static int] = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    producerDone: ptr Atomic[bool]

  ConsumerContext[S: static int] = object
    id: int
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    manager: ptr DebraManager[MaxThreads]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]

  HeartbeatContext[S: static int] = object
    queue: ptr UnboundedSipmuc[S, int, MaxThreads]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]
    done: ptr Atomic[bool]

proc producer[S: static int](ctx: ptr ProducerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    dlog("producer started")
    for i in 1 .. ItemCount:
      ctx.queue[].push(i)
      when defined(stressDebug):
        if i mod 1000 == 0:
          dlog("producer pushed " & $i)
    dlog("producer DONE pushing, setting producerDone")
    ctx.producerDone[].store(true, moRelease)
    dlog("producer EXIT")

proc consumer[S: static int](ctx: ptr ConsumerContext[S]) {.thread.} =
  {.cast(gcsafe).}:
    dlog("consumer " & $ctx.id & " started")
    let handle = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(handle)
    var popCount = 0
    when defined(stressDebug):
      var observedDone = false
    while true:
      let item = c.pop()
      if item.isSome:
        let val = item.get - 1 # Items are 1-indexed
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        let total = ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1
        inc popCount
        when defined(stressDebug):
          if popCount mod 1000 == 0:
            dlog(
              "consumer " & $ctx.id & " popped " & $popCount & " total=" & $total
            )
        if total >= ItemCount:
          dlog(
            "consumer " & $ctx.id & " HIT_TARGET total=" & $total &
              " popCount=" & $popCount
          )
          break
      elif ctx.producerDone[].load(moAcquire):
        when defined(stressDebug):
          if not observedDone:
            observedDone = true
            dlog(
              "consumer " & $ctx.id & " observed producerDone, total=" &
                $ctx.totalConsumed[].load(moRelaxed) & " popCount=" & $popCount
            )
        if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
          dlog(
            "consumer " & $ctx.id & " EXIT_VIA_DONE total=" &
              $ctx.totalConsumed[].load(moRelaxed) & " popCount=" & $popCount
          )
          break
    dlog("consumer " & $ctx.id & " EXIT popCount=" & $popCount)

when defined(stressDebug):
  proc heartbeat[S: static int](ctx: ptr HeartbeatContext[S]) {.thread.} =
    {.cast(gcsafe).}:
      while not ctx.done[].load(moRelaxed):
        sleep(5000)
        if ctx.done[].load(moRelaxed):
          break
        dlog(
          "HEARTBEAT total=" & $ctx.totalConsumed[].load(moRelaxed) &
            " producerDone=" & $ctx.producerDone[].load(moRelaxed) &
            " segCount=" & $ctx.queue[].segmentCount()
        )

suite "UnboundedSipmuc threaded stress":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]
    totalConsumed: Atomic[int]
    heartbeatDone: Atomic[bool]

  template resetState() =
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    heartbeatDone.store(false, moRelaxed)

  setup:
    resetState()

  when defined(stress):
    test "high segment turnover (50x)":
      for run in 1 .. StressIterations:
        resetState()
        dlog("=== TEST high segment turnover run=" & $run & " START ===")
        var manager = initDebraManager[MaxThreads]()
        var queue = newUnboundedSipmuc[8, int, MaxThreads](addr manager)
        var prodCtx = ProducerContext[8](
          queue: addr queue, producerDone: addr producerDone
        )
        var consCtxs: array[ConsumerCount, ConsumerContext[8]]
        for i in 0 ..< ConsumerCount:
          consCtxs[i] = ConsumerContext[8](
            id: i,
            queue: addr queue,
            manager: addr manager,
            received: addr received,
            duplicateFound: addr duplicateFound,
            producerDone: addr producerDone,
            totalConsumed: addr totalConsumed,
          )

        var prodThread: Thread[ptr ProducerContext[8]]
        var consThreads: array[ConsumerCount, Thread[ptr ConsumerContext[8]]]

        when defined(stressDebug):
          var hbCtx = HeartbeatContext[8](
            queue: addr queue,
            producerDone: addr producerDone,
            totalConsumed: addr totalConsumed,
            done: addr heartbeatDone,
          )
          var hbThread: Thread[ptr HeartbeatContext[8]]
          createThread(hbThread, heartbeat[8], addr hbCtx)

        createThread(prodThread, producer[8], addr prodCtx)
        for i in 0 ..< ConsumerCount:
          createThread(consThreads[i], consumer[8], addr consCtxs[i])

        dlog("main: joining producer (run=" & $run & ")")
        joinThread(prodThread)
        for i in 0 ..< ConsumerCount:
          joinThread(consThreads[i])
        when defined(stressDebug):
          heartbeatDone.store(true, moRelaxed)
          joinThread(hbThread)
        dlog("main: ALL JOINED (run=" & $run & ")")

        check(not duplicateFound.load(moRelaxed))
        for i in 0 ..< ItemCount:
          check(received[i].load(moRelaxed))
        dlog("=== TEST high segment turnover run=" & $run & " END ===")
