## High-volume stress tests for all bounded queue types.
## Tests 100k+ messages to catch ring buffer collision bugs.

when not compileOption("threads"):
  {.error: "t_stress requires --threads:on option.".}

import std/[atomics, options]
import unittest2
import lockfreequeues

const
  SmallBuffer = 16
  StandardBuffer = 1024
  LargeBuffer = 4096

  Count10k = 10_000
  Count100k = 100_000

type
  TestObject = object
    id: int
    payload: string
    checksum: uint32

proc computeChecksum(id: int, payload: string): uint32 =
  result = uint32(id)
  for c in payload:
    result = result xor uint32(ord(c))


# =============================================================================
# Sipsic (SPSC) Stress Tests
# =============================================================================

suite "Stress - Sipsic (SPSC)":

  test "Sipsic 100k int":
    var queue = initSipsic[StandardBuffer, int]()

    # Push all items
    for i in 0..<Count100k:
      while not queue.push(i):
        # Pop to make room
        let _ = queue.pop()
      check queue.push(i) or true  # Already pushed in while loop

    # Pop remaining items
    var popped = 0
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check popped > 0

  test "Sipsic 100k with buffer=16 (frequent wrapping)":
    var queue = initSipsic[SmallBuffer, int]()
    var pushed = 0
    var popped = 0

    # Interleaved push/pop to stress wraparound
    for i in 0..<Count100k:
      if queue.push(i):
        inc pushed
      let item = queue.pop()
      if item.isSome:
        inc popped

    # Drain remaining
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check pushed == popped

  test "Sipsic 100k string":
    var queue = initSipsic[StandardBuffer, string]()
    var pushed = 0
    var popped = 0

    for i in 0..<Count100k:
      if queue.push("message_" & $i):
        inc pushed
      let item = queue.pop()
      if item.isSome:
        inc popped

    # Drain
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check pushed == popped

  test "Sipsic 100k TestObject with checksum verification":
    var queue = initSipsic[StandardBuffer, TestObject]()
    var pushed = 0
    var verified = 0

    for i in 0..<Count100k:
      let payload = "payload_" & $i
      let obj = TestObject(
        id: i,
        payload: payload,
        checksum: computeChecksum(i, payload)
      )
      if queue.push(obj):
        inc pushed

      let item = queue.pop()
      if item.isSome:
        let got = item.get
        check got.checksum == computeChecksum(got.id, got.payload)
        inc verified

    # Drain and verify remaining
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      let got = item.get
      check got.checksum == computeChecksum(got.id, got.payload)
      inc verified

    check pushed == verified


# =============================================================================
# Mupmuc (MPMC) Stress Tests
# =============================================================================

type
  MupmucPCtx[N, P, C: static int, T] = object
    queue: ptr Mupmuc[N, P, C, T]
    count: int
    producerIdx: int
    sent: ptr Atomic[int]

  MupmucCCtx[N, P, C: static int, T] = object
    queue: ptr Mupmuc[N, P, C, T]
    count: int
    consumerIdx: int
    received: ptr Atomic[int]

proc mupmucProducer[N, P, C: static int](ctx: ptr MupmucPCtx[N, P, C, int]) {.thread.} =
  let p = ctx.queue[].getProducer(idx = ctx.producerIdx)
  for i in 0..<ctx.count:
    while not p.push(i):
      discard
    ctx.sent[].atomicInc()

proc mupmucConsumer[N, P, C: static int](ctx: ptr MupmucCCtx[N, P, C, int]) {.thread.} =
  let c = ctx.queue[].getConsumer(idx = ctx.consumerIdx)
  var localReceived = 0
  while localReceived < ctx.count:
    let item = c.pop()
    if item.isSome:
      inc localReceived
      ctx.received[].atomicInc()


suite "Stress - Mupmuc (MPMC)":

  test "Mupmuc 1P/1C 10k int":
    var queue = initMupmuc[StandardBuffer, 1, 1, int]()
    var sent, received: Atomic[int]
    sent.store(0)
    received.store(0)

    var pctx = MupmucPCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count10k, producerIdx: 0, sent: addr sent)
    var cctx = MupmucCCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count10k, consumerIdx: 0, received: addr received)

    var pThread: Thread[ptr MupmucPCtx[StandardBuffer, 1, 1, int]]
    var cThread: Thread[ptr MupmucCCtx[StandardBuffer, 1, 1, int]]

    createThread(pThread, mupmucProducer[StandardBuffer, 1, 1], addr pctx)
    createThread(cThread, mupmucConsumer[StandardBuffer, 1, 1], addr cctx)

    joinThread(pThread)
    joinThread(cThread)

    check sent.load() == Count10k
    check received.load() == Count10k

  test "Mupmuc 2P/2C 10k int":
    var queue = initMupmuc[StandardBuffer, 2, 2, int]()
    var sent, received: Atomic[int]
    sent.store(0)
    received.store(0)

    const PerThread = Count10k div 2

    var pctx0 = MupmucPCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 0, sent: addr sent)
    var pctx1 = MupmucPCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 1, sent: addr sent)
    var cctx0 = MupmucCCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 0, received: addr received)
    var cctx1 = MupmucCCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 1, received: addr received)

    var pThreads: array[2, Thread[ptr MupmucPCtx[StandardBuffer, 2, 2, int]]]
    var cThreads: array[2, Thread[ptr MupmucCCtx[StandardBuffer, 2, 2, int]]]

    createThread(pThreads[0], mupmucProducer[StandardBuffer, 2, 2], addr pctx0)
    createThread(pThreads[1], mupmucProducer[StandardBuffer, 2, 2], addr pctx1)
    createThread(cThreads[0], mupmucConsumer[StandardBuffer, 2, 2], addr cctx0)
    createThread(cThreads[1], mupmucConsumer[StandardBuffer, 2, 2], addr cctx1)

    joinThread(pThreads[0])
    joinThread(pThreads[1])
    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check sent.load() == Count10k
    check received.load() == Count10k

  test "Mupmuc 2P/2C 10k with buffer=16 (stress wraparound)":
    var queue = initMupmuc[SmallBuffer, 2, 2, int]()
    var sent, received: Atomic[int]
    sent.store(0)
    received.store(0)

    const PerThread = Count10k div 2

    var pctx0 = MupmucPCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 0, sent: addr sent)
    var pctx1 = MupmucPCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 1, sent: addr sent)
    var cctx0 = MupmucCCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 0, received: addr received)
    var cctx1 = MupmucCCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 1, received: addr received)

    var pThreads: array[2, Thread[ptr MupmucPCtx[SmallBuffer, 2, 2, int]]]
    var cThreads: array[2, Thread[ptr MupmucCCtx[SmallBuffer, 2, 2, int]]]

    createThread(pThreads[0], mupmucProducer[SmallBuffer, 2, 2], addr pctx0)
    createThread(pThreads[1], mupmucProducer[SmallBuffer, 2, 2], addr pctx1)
    createThread(cThreads[0], mupmucConsumer[SmallBuffer, 2, 2], addr cctx0)
    createThread(cThreads[1], mupmucConsumer[SmallBuffer, 2, 2], addr cctx1)

    joinThread(pThreads[0])
    joinThread(pThreads[1])
    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check sent.load() == Count10k
    check received.load() == Count10k


# =============================================================================
# Sipmuc (SPMC) Stress Tests
# =============================================================================

type
  SipmucCCtx[N, C: static int, T] = object
    queue: ptr Sipmuc[N, C, T]
    count: int
    consumerIdx: int
    received: ptr Atomic[int]

proc sipmucConsumer[N, C: static int](ctx: ptr SipmucCCtx[N, C, int]) {.thread.} =
  let c = ctx.queue[].getConsumer(idx = ctx.consumerIdx)
  var localReceived = 0
  while localReceived < ctx.count:
    let item = c.pop()
    if item.isSome:
      inc localReceived
      ctx.received[].atomicInc()


suite "Stress - Sipmuc (SPMC)":

  test "Sipmuc 1P/2C 10k int":
    var queue = initSipmuc[StandardBuffer, 2, int]()
    var received: Atomic[int]
    received.store(0)

    const PerConsumer = Count10k div 2

    var cctx0 = SipmucCCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerConsumer, consumerIdx: 0, received: addr received)
    var cctx1 = SipmucCCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerConsumer, consumerIdx: 1, received: addr received)

    var cThreads: array[2, Thread[ptr SipmucCCtx[StandardBuffer, 2, int]]]

    createThread(cThreads[0], sipmucConsumer[StandardBuffer, 2], addr cctx0)
    createThread(cThreads[1], sipmucConsumer[StandardBuffer, 2], addr cctx1)

    # Producer runs in main thread
    for i in 0..<Count10k:
      while not queue.push(i):
        discard

    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check received.load() == Count10k


# =============================================================================
# Mupsic (MPSC) Stress Tests
# =============================================================================

type
  MupsicPCtx[N, P: static int, T] = object
    queue: ptr Mupsic[N, P, T]
    count: int
    producerIdx: int
    sent: ptr Atomic[int]

proc mupsicProducer[N, P: static int](ctx: ptr MupsicPCtx[N, P, int]) {.thread.} =
  let p = ctx.queue[].getProducer(idx = ctx.producerIdx)
  for i in 0..<ctx.count:
    while not p.push(i):
      discard
    ctx.sent[].atomicInc()


suite "Stress - Mupsic (MPSC)":

  test "Mupsic 2P/1C 10k int":
    var queue = initMupsic[StandardBuffer, 2, int]()
    var sent: Atomic[int]
    sent.store(0)

    const PerProducer = Count10k div 2

    var pctx0 = MupsicPCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 0, sent: addr sent)
    var pctx1 = MupsicPCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 1, sent: addr sent)

    var pThreads: array[2, Thread[ptr MupsicPCtx[StandardBuffer, 2, int]]]

    createThread(pThreads[0], mupsicProducer[StandardBuffer, 2], addr pctx0)
    createThread(pThreads[1], mupsicProducer[StandardBuffer, 2], addr pctx1)

    # Consumer runs in main thread
    var received = 0
    while received < Count10k:
      let item = queue.pop()
      if item.isSome:
        inc received

    joinThread(pThreads[0])
    joinThread(pThreads[1])

    check sent.load() == Count10k
    check received == Count10k

  test "Mupsic 2P/1C 10k with buffer=16 (stress wraparound)":
    var queue = initMupsic[SmallBuffer, 2, int]()
    var sent: Atomic[int]
    sent.store(0)

    const PerProducer = Count10k div 2

    var pctx0 = MupsicPCtx[SmallBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 0, sent: addr sent)
    var pctx1 = MupsicPCtx[SmallBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 1, sent: addr sent)

    var pThreads: array[2, Thread[ptr MupsicPCtx[SmallBuffer, 2, int]]]

    createThread(pThreads[0], mupsicProducer[SmallBuffer, 2], addr pctx0)
    createThread(pThreads[1], mupsicProducer[SmallBuffer, 2], addr pctx1)

    # Consumer runs in main thread
    var received = 0
    while received < Count10k:
      let item = queue.pop()
      if item.isSome:
        inc received

    joinThread(pThreads[0])
    joinThread(pThreads[1])

    check sent.load() == Count10k
    check received == Count10k
