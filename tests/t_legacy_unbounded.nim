import options
import unittest2
import debra
import lockfreequeues
import lockfreequeues/atomic_dsl

const
  ItemsToTest = 5000
  HalfItems = ItemsToTest div 2

# ---------------------------------------------------------------------------
# SPSC Unbounded Threading
# ---------------------------------------------------------------------------
type SpscUnboundedCtx = object
  queue: ptr UnboundedSipsic[16, int]
  received: ptr array[ItemsToTest, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producerDone: ptr Atomic[bool]

proc spscUnboundedProd(ctx: ptr SpscUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducer()
    for i in 1 .. ItemsToTest:
      p.push(i)
    ctx.producerDone[].store(true, moRelease)

proc spscUnboundedCons(ctx: ptr SpscUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    var c = ctx.queue[].getConsumer()
    var consumed = 0
    while consumed < ItemsToTest:
      let item = c.pop()
      if item.isSome:
        let val = item.get - 1
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        inc consumed
      elif ctx.producerDone[].load(moAcquire):
        discard

# ---------------------------------------------------------------------------
# MPSC Unbounded Threading
# ---------------------------------------------------------------------------
type MpscUnboundedCtx = object
  queue: ptr UnboundedMupsic[16, int, 8]
  manager: ptr DebraManager[8]
  received: ptr array[ItemsToTest, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producersDone: ptr Atomic[int]
  producerIdx: int

proc mpscUnboundedProd(ctx: ptr MpscUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let h = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(h)
    let base = ctx.producerIdx * HalfItems
    for i in 1 .. HalfItems:
      p.push(base + i)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc mpscUnboundedCons(ctx: ptr MpscUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let h = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(h)
    var consumed = 0
    while consumed < ItemsToTest:
      let item = c.pop()
      if item.isSome:
        let val = item.get - 1
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        inc consumed
      elif ctx.producersDone[].load(moAcquire) >= 2:
        discard

# ---------------------------------------------------------------------------
# SPMC Unbounded Threading
# ---------------------------------------------------------------------------
type SpmcUnboundedCtx = object
  queue: ptr UnboundedSipmuc[16, int, 8]
  manager: ptr DebraManager[8]
  received: ptr array[ItemsToTest, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producerDone: ptr Atomic[bool]
  totalConsumed: ptr Atomic[int]

proc spmcUnboundedProd(ctx: ptr SpmcUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let h = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(h)
    for i in 1 .. ItemsToTest:
      p.push(i)
    ctx.producerDone[].store(true, moRelease)

proc spmcUnboundedCons(ctx: ptr SpmcUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let h = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(h)
    while true:
      let item = c.pop()
      if item.isSome:
        let val = item.get - 1
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemsToTest:
          break
      elif ctx.producerDone[].load(moAcquire):
        if ctx.totalConsumed[].load(moRelaxed) >= ItemsToTest:
          break

# ---------------------------------------------------------------------------
# MPMC Unbounded Threading
# ---------------------------------------------------------------------------
type MpmcUnboundedCtx = object
  queue: ptr UnboundedMupmuc[16, int, 8]
  manager: ptr DebraManager[8]
  received: ptr array[ItemsToTest, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producersDone: ptr Atomic[int]
  totalConsumed: ptr Atomic[int]
  producerIdx: int

proc mpmcUnboundedProd(ctx: ptr MpmcUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let h = registerThread(ctx.manager[])
    var p = ctx.queue[].getProducer(h)
    let base = ctx.producerIdx * HalfItems
    for i in 1 .. HalfItems:
      p.push(base + i)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc mpmcUnboundedCons(ctx: ptr MpmcUnboundedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let h = registerThread(ctx.manager[])
    var c = ctx.queue[].getConsumer(h)
    while true:
      let item = c.pop()
      if item.isSome:
        let val = item.get - 1
        if ctx.received[val].exchange(true, moRelaxed):
          ctx.duplicateFound[].store(true, moRelaxed)
        if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemsToTest:
          break
      elif ctx.producersDone[].load(moAcquire) >= 2:
        if ctx.totalConsumed[].load(moRelaxed) >= ItemsToTest:
          break

# ===========================================================================
# Test Suites
# ===========================================================================

suite "Legacy Unbounded Sipsic (SPSC)":
  test "lifecycle, segment growth, and FIFO ordering":
    var q = newUnboundedSipsic[4, int]()
    check(q.segmentCount == 1)
    check(q.len == 0)

    # Push across multiple segments (10 items into segments of 4)
    for i in 1 .. 10:
      q.push(i)
    check(q.len == 10)
    check(q.segmentCount >= 3)

    for i in 1 .. 10:
      let item = q.pop()
      check(item.isSome)
      check(item.get == i)

    check(q.len == 0)
    check(q.pop().isNone)

  test "threaded SPSC execution":
    var q = newUnboundedSipsic[16, int]()
    var
      received: array[ItemsToTest, Atomic[bool]]
      duplicateFound: Atomic[bool]
      producerDone: Atomic[bool]

    for i in 0 ..< ItemsToTest:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)

    var ctx = SpscUnboundedCtx(
      queue: addr q,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
    )
    var prodTh, consTh: Thread[ptr SpscUnboundedCtx]
    createThread(prodTh, spscUnboundedProd, addr ctx)
    createThread(consTh, spscUnboundedCons, addr ctx)
    joinThread(prodTh)
    joinThread(consTh)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemsToTest:
      check(received[i].load(moRelaxed))

suite "Legacy Unbounded Mupsic (MPSC)":
  test "basic push/pop and len":
    var mgr = initDebraManager[8]()
    let consH = registerThread(mgr)
    var q = newUnboundedMupsic[16, int, 8](addr mgr, consH)
    let prodH = registerThread(mgr)
    var p = q.getProducer(prodH)

    for i in 1 .. 20:
      p.push(i)
    check(q.len == 20)

    for i in 1 .. 20:
      let item = q.pop()
      check(item.isSome)
      check(item.get == i)
    check(q.len == 0)

  test "threaded MPSC execution":
    var mgr = initDebraManager[8]()
    var q = newUnboundedMupsic[16, int, 8](addr mgr)
    var
      received: array[ItemsToTest, Atomic[bool]]
      duplicateFound: Atomic[bool]
      producersDone: Atomic[int]

    for i in 0 ..< ItemsToTest:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)

    var pCtx0 = MpscUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0,
    )
    var pCtx1 = MpscUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 1,
    )
    var cCtx = MpscUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0,
    )

    var prodTh0, prodTh1, consTh: Thread[ptr MpscUnboundedCtx]
    createThread(prodTh0, mpscUnboundedProd, addr pCtx0)
    createThread(prodTh1, mpscUnboundedProd, addr pCtx1)
    createThread(consTh, mpscUnboundedCons, addr cCtx)

    joinThread(prodTh0)
    joinThread(prodTh1)
    joinThread(consTh)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemsToTest:
      check(received[i].load(moRelaxed))

suite "Legacy Unbounded Sipmuc (SPMC)":
  test "basic push and multiple consumer pops":
    var mgr = initDebraManager[8]()
    var q = newUnboundedSipmuc[16, int, 8](addr mgr)
    let prodH = registerThread(mgr)
    let consH1 = registerThread(mgr)
    let consH2 = registerThread(mgr)

    var p = q.getProducer(prodH)
    var c1 = q.getConsumer(consH1)
    var c2 = q.getConsumer(consH2)

    p.push(111)
    p.push(222)
    check(c1.pop().get == 111)
    check(c2.pop().get == 222)
    check(c1.pop().isNone)

  test "threaded SPMC execution":
    var mgr = initDebraManager[8]()
    var q = newUnboundedSipmuc[16, int, 8](addr mgr)
    var
      received: array[ItemsToTest, Atomic[bool]]
      duplicateFound: Atomic[bool]
      producerDone: Atomic[bool]
      totalConsumed: Atomic[int]

    for i in 0 ..< ItemsToTest:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

    var ctx = SpmcUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed,
    )

    var prodTh: Thread[ptr SpmcUnboundedCtx]
    var consTh0, consTh1: Thread[ptr SpmcUnboundedCtx]

    createThread(prodTh, spmcUnboundedProd, addr ctx)
    createThread(consTh0, spmcUnboundedCons, addr ctx)
    createThread(consTh1, spmcUnboundedCons, addr ctx)

    joinThread(prodTh)
    joinThread(consTh0)
    joinThread(consTh1)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemsToTest:
      check(received[i].load(moRelaxed))

suite "Legacy Unbounded Mupmuc (MPMC)":
  test "basic multi-producer multi-consumer":
    var mgr = initDebraManager[8]()
    var q = newUnboundedMupmuc[16, int, 8](addr mgr)
    let pH1 = registerThread(mgr)
    let pH2 = registerThread(mgr)
    let cH1 = registerThread(mgr)
    let cH2 = registerThread(mgr)

    var p1 = q.getProducer(pH1)
    var p2 = q.getProducer(pH2)
    var c1 = q.getConsumer(cH1)
    var c2 = q.getConsumer(cH2)

    p1.push(10)
    p2.push(20)
    check(c1.pop().get == 10)
    check(c2.pop().get == 20)
    check(c1.pop().isNone)

  test "threaded MPMC execution":
    var mgr = initDebraManager[8]()
    var q = newUnboundedMupmuc[16, int, 8](addr mgr)
    var
      received: array[ItemsToTest, Atomic[bool]]
      duplicateFound: Atomic[bool]
      producersDone: Atomic[int]
      totalConsumed: Atomic[int]

    for i in 0 ..< ItemsToTest:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)

    var pCtx0 = MpmcUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      totalConsumed: addr totalConsumed,
      producerIdx: 0,
    )
    var pCtx1 = MpmcUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      totalConsumed: addr totalConsumed,
      producerIdx: 1,
    )
    var cCtx0 = MpmcUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      totalConsumed: addr totalConsumed,
      producerIdx: 0,
    )
    var cCtx1 = MpmcUnboundedCtx(
      queue: addr q,
      manager: addr mgr,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      totalConsumed: addr totalConsumed,
      producerIdx: 0,
    )

    var prodTh0, prodTh1, consTh0, consTh1: Thread[ptr MpmcUnboundedCtx]
    createThread(prodTh0, mpmcUnboundedProd, addr pCtx0)
    createThread(prodTh1, mpmcUnboundedProd, addr pCtx1)
    createThread(consTh0, mpmcUnboundedCons, addr cCtx0)
    createThread(consTh1, mpmcUnboundedCons, addr cCtx1)

    joinThread(prodTh0)
    joinThread(prodTh1)
    joinThread(consTh0)
    joinThread(consTh1)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemsToTest:
      check(received[i].load(moRelaxed))
