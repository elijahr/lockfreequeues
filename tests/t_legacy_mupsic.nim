import options
import unittest2
import lockfreequeues
import lockfreequeues/atomic_dsl

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount

type
  MupsicThreadContext[N: static int] = object
    queue: ptr Mupsic[N, ProducerCount, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producersDone: ptr Atomic[int]
    producerIdx: int

proc mupsicProducer[N: static int](ctx: ptr MupsicThreadContext[N]) {.thread.} =
  var p = ctx.queue[].getProducer()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1 .. ItemsPerProducer:
    while not p.push(base + i):
      discard
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc mupsicConsumer[N: static int](ctx: ptr MupsicThreadContext[N]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      discard

suite "Legacy Mupsic - Single-threaded":
  test "capacity and producerCount metadata":
    var q = initMupsic[8, 4, int]()
    check(q.capacity == 8)
    check(q.producerCount == 4)
    check(q.empty == true)
    check(q.full == false)

  test "producer push and consumer pop FIFO":
    var q = initMupsic[8, 4, int]()
    var p0 = q.getProducer(0)
    for i in 1 .. 8:
      check(p0.push(i) == true)
    check(q.full == true)
    check(p0.push(999) == false)

    for i in 1 .. 8:
      let item = q.pop()
      check(item.isSome)
      check(item.get == i)
    check(q.empty == true)
    check(q.pop().isNone)

  test "multiple producers interleaving":
    var q = initMupsic[8, 2, int]()
    var p0 = q.getProducer(0)
    var p1 = q.getProducer(1)

    check(p0.push(10) == true)
    check(p1.push(20) == true)
    check(p0.push(30) == true)
    check(p1.push(40) == true)

    check(q.pop().get == 10)
    check(q.pop().get == 20)
    check(q.pop().get == 30)
    check(q.pop().get == 40)
    check(q.empty == true)

  test "batch push and batch pop":
    var q = initMupsic[8, 2, int]()
    var p0 = q.getProducer(0)

    let rem = p0.push(@[1, 2, 3, 4])
    check(rem.isNone)

    let popped = q.pop(4)
    check(popped.isSome)
    check(popped.get == @[1, 2, 3, 4])
    check(q.empty == true)

suite "Legacy Mupsic - Multi-threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)

  test "threaded high contention (N=16, P=4)":
    var queue = initMupsic[16, ProducerCount, int]()

    var contexts: array[ProducerCount, MupsicThreadContext[16]]
    for i in 0 ..< ProducerCount:
      contexts[i] = MupsicThreadContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = MupsicThreadContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0,
    )

    var prodThreads: array[ProducerCount, Thread[ptr MupsicThreadContext[16]]]
    var consThread: Thread[ptr MupsicThreadContext[16]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], mupsicProducer[16], addr contexts[i])
    createThread(consThread, mupsicConsumer[16], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "threaded normal capacity (N=64, P=4)":
    var queue = initMupsic[64, ProducerCount, int]()

    var contexts: array[ProducerCount, MupsicThreadContext[64]]
    for i in 0 ..< ProducerCount:
      contexts[i] = MupsicThreadContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        producerIdx: i,
      )

    var consCtx = MupsicThreadContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      producerIdx: 0,
    )

    var prodThreads: array[ProducerCount, Thread[ptr MupsicThreadContext[64]]]
    var consThread: Thread[ptr MupsicThreadContext[64]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], mupsicProducer[64], addr contexts[i])
    createThread(consThread, mupsicConsumer[64], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
