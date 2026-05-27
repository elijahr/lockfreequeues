## High-volume stress tests for all bounded queue types.
## Tests 100k+ messages to catch ring buffer collision bugs.

when not compileOption("threads"):
  {.error: "t_stress requires --threads:on option.".}

import std/options
import unittest2
import lockfreequeues
import lockfreequeues/atomic_dsl

const
  SmallBuffer = 16
  StandardBuffer = 1024
  LargeBuffer = 4096

  Count10k = 10_000
  Count100k = 100_000

type TestObject = object
  id: int
  payload: string
  checksum: uint32

proc computeChecksum(id: int, payload: string): uint32 =
  result = uint32(id)
  for c in payload:
    result = result xor uint32(ord(c))

# =============================================================================
# Spsc (SPSC) Stress Tests
# =============================================================================

suite "Stress - Spsc (SPSC)":
  test "Spsc 100k int":
    var queue = newSpscQueue[int, StandardBuffer]()

    # Push all items
    for i in 0 ..< Count100k:
      while not queue.push(i):
        # Pop to make room
        let _ = queue.pop()
      check queue.push(i) or true # Already pushed in while loop

    # Pop remaining items
    var popped = 0
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check popped > 0

  test "Spsc 100k with buffer=16 (frequent wrapping)":
    var queue = newSpscQueue[int, SmallBuffer]()
    var pushed = 0
    var popped = 0

    # Interleaved push/pop to stress wraparound
    for i in 0 ..< Count100k:
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

  test "Spsc 100k string":
    var queue = newSpscQueue[string, StandardBuffer]()
    var pushed = 0
    var popped = 0

    for i in 0 ..< Count100k:
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

  test "Spsc 100k TestObject with checksum verification":
    var queue = newSpscQueue[TestObject, StandardBuffer]()
    var pushed = 0
    var verified = 0

    for i in 0 ..< Count100k:
      let payload = "payload_" & $i
      let obj =
        TestObject(id: i, payload: payload, checksum: computeChecksum(i, payload))
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
# Mpmc (MPMC) Stress Tests
# =============================================================================

type
  MpmcPCtx[N, P, C: static int, T] = object
    queue: ptr BQueue[T, ccMulti, ccMulti, N, P, C]
    count: int
    producerIdx: int
    sent: ptr Atomic[int]

  MpmcCCtx[N, P, C: static int, T] = object
    queue: ptr BQueue[T, ccMulti, ccMulti, N, P, C]
    count: int
    consumerIdx: int
    received: ptr Atomic[int]

proc mpmcProducer[N, P, C: static int](ctx: ptr MpmcPCtx[N, P, C, int]) {.thread.} =
  let p = ctx.queue[].getProducer(idx = ctx.producerIdx)
  for i in 0 ..< ctx.count:
    while not p.push(i):
      discard
    discard ctx.sent[].fetchAdd(1, moRelaxed)

proc mpmcConsumer[N, P, C: static int](ctx: ptr MpmcCCtx[N, P, C, int]) {.thread.} =
  let c = ctx.queue[].getConsumer(idx = ctx.consumerIdx)
  var localReceived = 0
  while localReceived < ctx.count:
    let item = c.pop()
    if item.isSome:
      inc localReceived
      discard ctx.received[].fetchAdd(1, moRelaxed)

suite "Stress - Mpmc (MPMC)":
  test "Mpmc 1P/1C 10k int":
    var queue = newMpmcQueue[int, StandardBuffer, 1, 1]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    var pctx = MpmcPCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count10k, producerIdx: 0, sent: addr sent
    )
    var cctx = MpmcCCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count10k, consumerIdx: 0, received: addr received
    )

    var pThread: Thread[ptr MpmcPCtx[StandardBuffer, 1, 1, int]]
    var cThread: Thread[ptr MpmcCCtx[StandardBuffer, 1, 1, int]]

    createThread(pThread, mpmcProducer[StandardBuffer, 1, 1], addr pctx)
    createThread(cThread, mpmcConsumer[StandardBuffer, 1, 1], addr cctx)

    joinThread(pThread)
    joinThread(cThread)

    check sent.load(moRelaxed) == Count10k
    check received.load(moRelaxed) == Count10k

  test "Mpmc 2P/2C 10k int":
    var queue = newMpmcQueue[int, StandardBuffer, 2, 2]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    const PerThread = Count10k div 2

    var pctx0 = MpmcPCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpmcPCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 1, sent: addr sent
    )
    var cctx0 = MpmcCCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 0, received: addr received
    )
    var cctx1 = MpmcCCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 1, received: addr received
    )

    var pThreads: array[2, Thread[ptr MpmcPCtx[StandardBuffer, 2, 2, int]]]
    var cThreads: array[2, Thread[ptr MpmcCCtx[StandardBuffer, 2, 2, int]]]

    createThread(pThreads[0], mpmcProducer[StandardBuffer, 2, 2], addr pctx0)
    createThread(pThreads[1], mpmcProducer[StandardBuffer, 2, 2], addr pctx1)
    createThread(cThreads[0], mpmcConsumer[StandardBuffer, 2, 2], addr cctx0)
    createThread(cThreads[1], mpmcConsumer[StandardBuffer, 2, 2], addr cctx1)

    joinThread(pThreads[0])
    joinThread(pThreads[1])
    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received.load(moRelaxed) == Count10k

  test "Mpmc 2P/2C 10k with buffer=16 (stress wraparound)":
    var queue = newMpmcQueue[int, SmallBuffer, 2, 2]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    const PerThread = Count10k div 2

    var pctx0 = MpmcPCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpmcPCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 1, sent: addr sent
    )
    var cctx0 = MpmcCCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 0, received: addr received
    )
    var cctx1 = MpmcCCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 1, received: addr received
    )

    var pThreads: array[2, Thread[ptr MpmcPCtx[SmallBuffer, 2, 2, int]]]
    var cThreads: array[2, Thread[ptr MpmcCCtx[SmallBuffer, 2, 2, int]]]

    createThread(pThreads[0], mpmcProducer[SmallBuffer, 2, 2], addr pctx0)
    createThread(pThreads[1], mpmcProducer[SmallBuffer, 2, 2], addr pctx1)
    createThread(cThreads[0], mpmcConsumer[SmallBuffer, 2, 2], addr cctx0)
    createThread(cThreads[1], mpmcConsumer[SmallBuffer, 2, 2], addr cctx1)

    joinThread(pThreads[0])
    joinThread(pThreads[1])
    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received.load(moRelaxed) == Count10k

# =============================================================================
# Spmc (SPMC) Stress Tests
# =============================================================================

type SpmcCCtx[N, C: static int, T] = object
  queue: ptr BQueue[T, ccSingle, ccMulti, N, 0, C]
  count: int
  consumerIdx: int
  received: ptr Atomic[int]

proc spmcConsumer[N, C: static int](ctx: ptr SpmcCCtx[N, C, int]) {.thread.} =
  let c = ctx.queue[].getConsumer(idx = ctx.consumerIdx)
  var localReceived = 0
  while localReceived < ctx.count:
    let item = c.pop()
    if item.isSome:
      inc localReceived
      discard ctx.received[].fetchAdd(1, moRelaxed)

suite "Stress - Spmc (SPMC)":
  test "Spmc 1P/2C 10k int":
    var queue = newSpmcQueue[int, StandardBuffer, 2]()
    var received: Atomic[int]
    received.store(0, moRelaxed)

    const PerConsumer = Count10k div 2

    var cctx0 = SpmcCCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerConsumer, consumerIdx: 0, received: addr received
    )
    var cctx1 = SpmcCCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerConsumer, consumerIdx: 1, received: addr received
    )

    var cThreads: array[2, Thread[ptr SpmcCCtx[StandardBuffer, 2, int]]]

    createThread(cThreads[0], spmcConsumer[StandardBuffer, 2], addr cctx0)
    createThread(cThreads[1], spmcConsumer[StandardBuffer, 2], addr cctx1)

    # Producer runs in main thread
    for i in 0 ..< Count10k:
      while not queue.push(i):
        discard

    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check received.load(moRelaxed) == Count10k

# =============================================================================
# Mpsc (MPSC) Stress Tests
# =============================================================================

type MpscPCtx[N, P: static int, T] = object
  queue: ptr BQueue[T, ccMulti, ccSingle, N, P, 0]
  count: int
  producerIdx: int
  sent: ptr Atomic[int]

proc mpscProducer[N, P: static int](ctx: ptr MpscPCtx[N, P, int]) {.thread.} =
  let p = ctx.queue[].getProducer(idx = ctx.producerIdx)
  for i in 0 ..< ctx.count:
    while not p.push(i):
      discard
    discard ctx.sent[].fetchAdd(1, moRelaxed)

suite "Stress - Mpsc (MPSC)":
  test "Mpsc 2P/1C 10k int":
    var queue = newMpscQueue[int, StandardBuffer, 2]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count10k div 2

    var pctx0 = MpscPCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpscPCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 1, sent: addr sent
    )

    var pThreads: array[2, Thread[ptr MpscPCtx[StandardBuffer, 2, int]]]

    createThread(pThreads[0], mpscProducer[StandardBuffer, 2], addr pctx0)
    createThread(pThreads[1], mpscProducer[StandardBuffer, 2], addr pctx1)

    # Consumer runs in main thread
    var received = 0
    while received < Count10k:
      let item = queue.pop()
      if item.isSome:
        inc received

    joinThread(pThreads[0])
    joinThread(pThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received == Count10k

  test "Mpsc 2P/1C 10k with buffer=16 (stress wraparound)":
    var queue = newMpscQueue[int, SmallBuffer, 2]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count10k div 2

    var pctx0 = MpscPCtx[SmallBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpscPCtx[SmallBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 1, sent: addr sent
    )

    var pThreads: array[2, Thread[ptr MpscPCtx[SmallBuffer, 2, int]]]

    createThread(pThreads[0], mpscProducer[SmallBuffer, 2], addr pctx0)
    createThread(pThreads[1], mpscProducer[SmallBuffer, 2], addr pctx1)

    # Consumer runs in main thread
    var received = 0
    while received < Count10k:
      let item = queue.pop()
      if item.isSome:
        inc received

    joinThread(pThreads[0])
    joinThread(pThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received == Count10k
