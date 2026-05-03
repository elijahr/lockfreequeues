## Unbounded queues throughput bench (Track 2 PR 2 Task 2.6).
##
## Splits the unbounded slice out of the legacy bench_throughput.nim into
## a standalone binary covering all four lockfreequeues unbounded
## variants at their natural shapes:
##
##   - UnboundedSipsic (spsc_unbounded): 1p1c only.
##   - UnboundedSipmuc (mpmc_unbounded, single producer + N consumers):
##     1p{1,2,4}c.
##   - UnboundedMupsic (mpsc_unbounded, N producers + 1 consumer):
##     {1,2,4}p1c.
##   - UnboundedMupmuc (mpmc_unbounded, N producers + N consumers):
##     {1,2,4} P x {1,2,4} C grid.
##
## All unbounded variants except Sipsic use DEBRA epoch reclamation;
## producer AND consumer threads must call `registerThread(manager)` on
## their own thread before obtaining a Producer/Consumer via
## `queue.getProducer(handle)` / `queue.getConsumer(handle)`. The
## harness here mirrors the legacy bench_throughput UnboundedMupsic
## path: spawn a worker thread, register-on-thread, then push/pop.
##
## Per-variant intdefines (design §2.5; lower than bounded because
## backing memory pool grows with messageCount on the unbounded queues):
##   -d:UnboundedSipsicRuns / UnboundedSipsicMessageCount   (3 / 500_000)
##   -d:UnboundedSipmucRuns / UnboundedSipmucMessageCount   (3 / 500_000)
##   -d:UnboundedMupsicRuns / UnboundedMupsicMessageCount   (3 / 500_000)
##   -d:UnboundedMupmucRuns / UnboundedMupmucMessageCount   (3 / 500_000)
##   -d:BenchUnboundedWarmup                                (default 2)
##
## Slug shapes:
##   lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c
##   lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p{1,2,4}c
##   lockfreequeues_unbounded_mupsic/mpsc_unbounded/{1,2,4}p1c
##   lockfreequeues_unbounded_mupmuc/mpmc_unbounded/{1,2,4}p{1,2,4}c

import std/[atomics, monotimes, options, os, parseopt, sets, strformat,
            syncio, times]
import ./bench_common
import ./adapters/lockfreequeues_unbounded_mupsic_adapter
import lockfreequeues/backoff
import lockfreequeues/unbounded_sipsic
import lockfreequeues/unbounded_sipmuc
import lockfreequeues/unbounded_mupmuc
import lockfreequeues/unbounded_mupsic
import debra

const
  UnboundedSipsicRuns* {.intdefine.} = 3
  UnboundedSipsicMessageCount* {.intdefine.} = 500_000
  UnboundedSipmucRuns* {.intdefine.} = 3
  UnboundedSipmucMessageCount* {.intdefine.} = 500_000
  UnboundedMupsicRuns* {.intdefine.} = 3
  UnboundedMupsicMessageCount* {.intdefine.} = 500_000
  UnboundedMupmucRuns* {.intdefine.} = 3
  UnboundedMupmucMessageCount* {.intdefine.} = 500_000
  BenchUnboundedWarmup* {.intdefine.} = 2

  SegmentSize = 64
  MaxThreads = 16
    ## Headroom for up to 8 producers + 8 consumers + DEBRA bookkeeping.

when defined(BenchUnboundedTestCompileTime):
  static:
    doAssert UnboundedSipsicRuns == 3
    doAssert UnboundedSipsicMessageCount == 500_000
    doAssert UnboundedSipmucRuns == 3
    doAssert UnboundedSipmucMessageCount == 500_000
    doAssert UnboundedMupsicRuns == 3
    doAssert UnboundedMupsicMessageCount == 500_000
    doAssert UnboundedMupmucRuns == 3
    doAssert UnboundedMupmucMessageCount == 500_000

# ---------- UnboundedSipsic harness (no DEBRA, plain SPSC) ----------

type
  USipsicProducerCtx[S: static int; T] = object
    queue: ptr UnboundedSipsic[S, T]
    count: int

  USipsicConsumerCtx[S: static int; T] = object
    queue: ptr UnboundedSipsic[S, T]
    count: int

proc usipsicProducerThread[S: static int; T](
    ctx: ptr USipsicProducerCtx[S, T]
) {.thread.} =
  for i in 0 ..< ctx.count:
    ctx.queue[].push(T(i))

proc usipsicConsumerThread[S: static int; T](
    ctx: ptr USipsicConsumerCtx[S, T]
) {.thread.} =
  var local = 0
  while local < ctx.count:
    let r = ctx.queue[].pop()
    if r.isSome:
      inc local
    else:
      backoffOnPeerWait()

proc runOneUSipsicRun[S: static int; T](
    queue: ptr UnboundedSipsic[S, T], messageCount: int
): float =
  var producerThread: Thread[ptr USipsicProducerCtx[S, T]]
  var consumerThread: Thread[ptr USipsicConsumerCtx[S, T]]
  var producerCtx = USipsicProducerCtx[S, T](queue: queue, count: messageCount)
  var consumerCtx = USipsicConsumerCtx[S, T](queue: queue, count: messageCount)
  let startTime = getMonoTime()
  createThread(producerThread, usipsicProducerThread[S, T], addr producerCtx)
  createThread(consumerThread, usipsicConsumerThread[S, T], addr consumerCtx)
  joinThread(producerThread)
  joinThread(consumerThread)
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUSipsicShape(em: var BMFEmitter, runs, warmup, messageCount: int) =
  let slug = "lockfreequeues_unbounded_sipsic/spsc_unbounded/1p1c"
  echo fmt"UnboundedSipsic 1p1c ({slug}):"
  for _ in 0 ..< warmup:
    var q = newUnboundedSipsic[SegmentSize, uint64]()
    discard runOneUSipsicRun(addr q, messageCount)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var q = newUnboundedSipsic[SegmentSize, uint64]()
    samples.add(runOneUSipsicRun(addr q, messageCount))
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- UnboundedSipmuc harness (single producer, N consumers, DEBRA) ----------

type
  USipmucProducerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UnboundedSipmuc[S, T, MaxT]
    count: int

  USipmucConsumerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UnboundedSipmuc[S, T, MaxT]
    manager: ptr DebraManager[MaxT]
    count: int

proc usipmucProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr USipmucProducerCtx[S, T, MaxT]
) {.thread.} =
  # Single-producer push goes through the queue object directly. No
  # DEBRA register needed for the producer (UnboundedSipmuc only retires
  # on consumer-side; the producer never traverses retired segments).
  for i in 0 ..< ctx.count:
    ctx.queue[].push(T(i))

proc usipmucConsumerThread[S: static int; T; MaxT: static int](
    ctx: ptr USipmucConsumerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var consumer = ctx.queue[].getConsumer(handle)
    var local = 0
    while local < ctx.count:
      let r = consumer.pop()
      if r.isSome:
        inc local
      else:
        backoffOnPeerWait()

proc runOneUSipmucRun[S: static int; T; MaxT: static int; C: static int](
    queue: ptr UnboundedSipmuc[S, T, MaxT],
    manager: ptr DebraManager[MaxT],
    messageCount: int,
): float =
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThread: Thread[ptr USipmucProducerCtx[S, T, MaxT]]
  var consumerThreads: array[C, Thread[ptr USipmucConsumerCtx[S, T, MaxT]]]
  var producerCtx = USipmucProducerCtx[S, T, MaxT](
    queue: queue, count: messageCount,
  )
  var consumerCtxs: array[C, USipmucConsumerCtx[S, T, MaxT]]
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = USipmucConsumerCtx[S, T, MaxT](
      queue: queue, manager: manager, count: count,
    )
  let startTime = getMonoTime()
  createThread(producerThread,
               usipmucProducerThread[S, T, MaxT],
               addr producerCtx)
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      usipmucConsumerThread[S, T, MaxT],
      addr consumerCtxs[i],
    )
  joinThread(producerThread)
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUSipmucShape[C: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_sipmuc/mpmc_unbounded/1p" & $C & "c"
  echo fmt"UnboundedSipmuc 1p{C}c ({slug}):"
  # Per-iteration teardown order (applies to both warmup and timed loops):
  #
  # 1. `reset(q)` invokes UnboundedSipmuc's `=destroy` hook, which calls
  #    `unbindClient(self.manager[])` (see src/lockfreequeues/unbounded_sipmuc.nim
  #    `=destroy`). In Nim 2.x ARC/ORC, `system.reset(x)` is equivalent
  #    to `=destroy(x); =wasMoved(x)` — it does NOT skip destructors. The
  #    `wasMoved` half also keeps end-of-iteration auto-destruction from
  #    re-running on a moved-from value.
  # 2. `reset(manager[])` then runs DebraManager's `=destroy` (drains
  #    limbo bags, asserts clientCount == 0). The queue MUST be destroyed
  #    first because step 2 verifies the manager has no live clients.
  # 3. `dealloc(manager)` releases the heap allocation. The manager is
  #    raw-allocated (`create`/`dealloc`) rather than `new`-allocated so
  #    the harness can measure cold queue allocation cost without ref
  #    cycles tying the manager's lifetime to the iterator scope.
  for _ in 0 ..< warmup:
    var manager = create(DebraManager[MaxThreads])
    manager[] = initDebraManager[MaxThreads]()
    var q = newUnboundedSipmuc[SegmentSize, uint64, MaxThreads](manager)
    discard runOneUSipmucRun[SegmentSize, uint64, MaxThreads, C](
      addr q, manager, messageCount)
    reset(q)
    reset(manager[])
    dealloc(manager)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var manager = create(DebraManager[MaxThreads])
    manager[] = initDebraManager[MaxThreads]()
    var q = newUnboundedSipmuc[SegmentSize, uint64, MaxThreads](manager)
    samples.add(runOneUSipmucRun[SegmentSize, uint64, MaxThreads, C](
      addr q, manager, messageCount))
    reset(q)
    reset(manager[])
    dealloc(manager)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- UnboundedMupsic harness (N producers, 1 consumer, DEBRA) ----------

type
  UMupsicProducerCtx2[S: static int; T; MaxT: static int] = object
    queue: ptr UnboundedMupsic[S, T, MaxT]
    manager: ptr DebraManager[MaxT]
    startIdx: int
    count: int

proc umupsicProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMupsicProducerCtx2[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(handle)
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      p.push(T(i))

proc runOneUMupsicRun[S: static int; T; MaxT: static int; P: static int](
    queue: ptr UnboundedMupsic[S, T, MaxT],
    manager: ptr DebraManager[MaxT],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  var producerThreads: array[P, Thread[ptr UMupsicProducerCtx2[S, T, MaxT]]]
  var producerCtxs: array[P, UMupsicProducerCtx2[S, T, MaxT]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = UMupsicProducerCtx2[S, T, MaxT](
      queue: queue, manager: manager,
      startIdx: nextStart, count: count,
    )
    nextStart += count
  # Consumer runs on the calling (main bench) thread because
  # UnboundedMupsicAdapter pre-registers a single consumer ThreadHandle
  # at init time and the queue holds that handle internally.
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      umupsicProducerThread[S, T, MaxT],
      addr producerCtxs[i],
    )
  var local = 0
  while local < messageCount:
    let r = queue[].pop()
    if r.isSome:
      inc local
    else:
      backoffOnPeerWait()
  for i in 0 ..< P: joinThread(producerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUMupsicShape[P: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_mupsic/mpsc_unbounded/" & $P & "p1c"
  echo fmt"UnboundedMupsic {P}p1c ({slug}):"
  for _ in 0 ..< warmup:
    var a = initUnboundedMupsicAdapter[SegmentSize, uint64, MaxThreads]()
    discard runOneUMupsicRun[SegmentSize, uint64, MaxThreads, P](
      a.queue, a.manager, messageCount)
    deinitUnboundedMupsicAdapter(a)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var a = initUnboundedMupsicAdapter[SegmentSize, uint64, MaxThreads]()
    samples.add(runOneUMupsicRun[SegmentSize, uint64, MaxThreads, P](
      a.queue, a.manager, messageCount))
    deinitUnboundedMupsicAdapter(a)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- UnboundedMupmuc harness (N producers, N consumers, DEBRA) ----------

type
  UMupmucProducerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UnboundedMupmuc[S, T, MaxT]
    manager: ptr DebraManager[MaxT]
    startIdx: int
    count: int

  UMupmucConsumerCtx[S: static int; T; MaxT: static int] = object
    queue: ptr UnboundedMupmuc[S, T, MaxT]
    manager: ptr DebraManager[MaxT]
    count: int

proc umupmucProducerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMupmucProducerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var producer = ctx.queue[].getProducer(handle)
    for i in ctx.startIdx ..< ctx.startIdx + ctx.count:
      producer.push(T(i))

proc umupmucConsumerThread[S: static int; T; MaxT: static int](
    ctx: ptr UMupmucConsumerCtx[S, T, MaxT]
) {.thread.} =
  {.cast(gcsafe).}:
    let handle = registerThread(ctx.manager[])
    var consumer = ctx.queue[].getConsumer(handle)
    var local = 0
    while local < ctx.count:
      let r = consumer.pop()
      if r.isSome:
        inc local
      else:
        backoffOnPeerWait()

proc runOneUMupmucRun[S: static int; T; MaxT: static int;
                      P: static int; C: static int](
    queue: ptr UnboundedMupmuc[S, T, MaxT],
    manager: ptr DebraManager[MaxT],
    messageCount: int,
): float =
  let baseP = messageCount div P
  let remP = messageCount mod P
  let baseC = messageCount div C
  let remC = messageCount mod C
  var producerThreads: array[P, Thread[ptr UMupmucProducerCtx[S, T, MaxT]]]
  var consumerThreads: array[C, Thread[ptr UMupmucConsumerCtx[S, T, MaxT]]]
  var producerCtxs: array[P, UMupmucProducerCtx[S, T, MaxT]]
  var consumerCtxs: array[C, UMupmucConsumerCtx[S, T, MaxT]]
  var nextStart = 0
  for i in 0 ..< P:
    let count = baseP + (if i < remP: 1 else: 0)
    producerCtxs[i] = UMupmucProducerCtx[S, T, MaxT](
      queue: queue, manager: manager,
      startIdx: nextStart, count: count,
    )
    nextStart += count
  for i in 0 ..< C:
    let count = baseC + (if i < remC: 1 else: 0)
    consumerCtxs[i] = UMupmucConsumerCtx[S, T, MaxT](
      queue: queue, manager: manager, count: count,
    )
  let startTime = getMonoTime()
  for i in 0 ..< P:
    createThread(
      producerThreads[i],
      umupmucProducerThread[S, T, MaxT],
      addr producerCtxs[i],
    )
  for i in 0 ..< C:
    createThread(
      consumerThreads[i],
      umupmucConsumerThread[S, T, MaxT],
      addr consumerCtxs[i],
    )
  for i in 0 ..< P: joinThread(producerThreads[i])
  for i in 0 ..< C: joinThread(consumerThreads[i])
  let elapsedNs = float(inNanoseconds(getMonoTime() - startTime))
  if elapsedNs <= 0.0: return 0.0
  result = float(messageCount) * 1_000_000.0 / elapsedNs

proc runUMupmucShape[P: static int; C: static int](
    em: var BMFEmitter,
    runs, warmup, messageCount: int,
) =
  let slug = "lockfreequeues_unbounded_mupmuc/mpmc_unbounded/" &
    $P & "p" & $C & "c"
  echo fmt"UnboundedMupmuc {P}p{C}c ({slug}):"
  # Per-iteration teardown order is identical to runUSipmucShape; see the
  # block comment there for why `reset(q)` must precede `reset(manager[])`
  # (and why reset DOES invoke `=destroy` under Nim 2.x ARC/ORC).
  for _ in 0 ..< warmup:
    var manager = create(DebraManager[MaxThreads])
    manager[] = initDebraManager[MaxThreads]()
    var q = newUnboundedMupmuc[SegmentSize, uint64, MaxThreads](manager)
    discard runOneUMupmucRun[SegmentSize, uint64, MaxThreads, P, C](
      addr q, manager, messageCount)
    reset(q)
    reset(manager[])
    dealloc(manager)
  var samples: seq[float] = @[]
  for _ in 0 ..< runs:
    var manager = create(DebraManager[MaxThreads])
    manager[] = initDebraManager[MaxThreads]()
    var q = newUnboundedMupmuc[SegmentSize, uint64, MaxThreads](manager)
    samples.add(runOneUMupmucRun[SegmentSize, uint64, MaxThreads, P, C](
      addr q, manager, messageCount))
    reset(q)
    reset(manager[])
    dealloc(manager)
  let m = mean(samples)
  let s = stddev(samples)
  echo fmt"  mean: {m:.1f} ops/ms"
  echo fmt"  stddev: {s:.1f}"
  echo fmt"  runs: {samples.len}"
  echo ""
  em.addMeasure(slug, "throughput_ops_ms", m, m - s, m + s)

# ---------- Variant dispatch ----------

const SupportedVariants =
  ["unbounded_sipsic", "unbounded_sipmuc",
   "unbounded_mupsic", "unbounded_mupmuc"]

proc runVariant(variant: string, em: var BMFEmitter) =
  case variant
  of "unbounded_sipsic":
    runUSipsicShape(em,
      UnboundedSipsicRuns, BenchUnboundedWarmup,
      UnboundedSipsicMessageCount)
  of "unbounded_sipmuc":
    runUSipmucShape[1](em, UnboundedSipmucRuns, BenchUnboundedWarmup,
      UnboundedSipmucMessageCount)
    runUSipmucShape[2](em, UnboundedSipmucRuns, BenchUnboundedWarmup,
      UnboundedSipmucMessageCount)
    when not defined(BenchSkipOversubscribed):
      runUSipmucShape[4](em, UnboundedSipmucRuns, BenchUnboundedWarmup,
        UnboundedSipmucMessageCount)
  of "unbounded_mupsic":
    # mupsic shapes are kept under BenchSkipOversubscribed: a single
    # consumer cannot trigger the round-robin starvation that hangs
    # sipmuc/mupmuc with C >= 4, and `mpsc_unbounded/4p1c` is in the
    # pre-split deletion-safety fixture.
    runUMupsicShape[1](em, UnboundedMupsicRuns, BenchUnboundedWarmup,
      UnboundedMupsicMessageCount)
    runUMupsicShape[2](em, UnboundedMupsicRuns, BenchUnboundedWarmup,
      UnboundedMupsicMessageCount)
    runUMupsicShape[4](em, UnboundedMupsicRuns, BenchUnboundedWarmup,
      UnboundedMupsicMessageCount)
  of "unbounded_mupmuc":
    # {1,2,4} P x {1,2,4} C grid (9 shapes). Shapes with P + C > 4
    # hang under 4-vCPU oversubscription: the round-robin consumer
    # ordering in unbounded_sipmuc/mupmuc forces strict per-shape
    # turn-taking, so a single descheduled consumer blocks every
    # other consumer. `-d:BenchSkipOversubscribed` (set in PR CI)
    # drops the offending shapes; the full grid still runs in
    # `bench-comparison.yml` nightly cron / on workflow_dispatch
    # where a beefier runner is available.
    runUMupmucShape[1, 1](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    runUMupmucShape[1, 2](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    runUMupmucShape[2, 1](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    runUMupmucShape[2, 2](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
      UnboundedMupmucMessageCount)
    when not defined(BenchSkipOversubscribed):
      runUMupmucShape[1, 4](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[2, 4](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[4, 1](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[4, 2](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
      runUMupmucShape[4, 4](em, UnboundedMupmucRuns, BenchUnboundedWarmup,
        UnboundedMupmucMessageCount)
  else:
    raise newException(ValueError, "unknown variant: " & variant)

when isMainModule:
  setStdIoUnbuffered()

  var bmfOutPath = ""
  var positional: seq[string] = @[]
  block parseCli:
    var p = initOptParser(commandLineParams())
    while true:
      p.next()
      case p.kind
      of cmdEnd: break
      of cmdLongOption, cmdShortOption:
        case p.key
        of "bmf-out":
          if p.val.len == 0:
            echo "Missing value for --bmf-out"
            quit 1
          bmfOutPath = p.val
        else:
          echo "Unknown flag: --", p.key
          quit 1
      of cmdArgument:
        positional.add(p.key)

  let supported = SupportedVariants.toHashSet
  let runVariants =
    if positional.len == 0:
      supported
    else:
      var groups = initHashSet[string]()
      for arg in positional:
        if arg notin supported:
          echo "Unknown variant: ", arg
          echo "Supported: ", SupportedVariants
          quit 1
        groups.incl arg
      groups

  echo "Unbounded Throughput Benchmark"
  echo "=============================="
  echo ""

  var emitter = initBMFEmitter()
  for v in SupportedVariants:
    if v in runVariants:
      runVariant(v, emitter)

  if bmfOutPath.len > 0:
    emitter.emit(bmfOutPath)
