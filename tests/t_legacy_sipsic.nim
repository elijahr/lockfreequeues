import options
import unittest2
import lockfreequeues
import lockfreequeues/atomic_dsl

const ItemCount = 10000

type SipsicThreadContext[N: static int] = object
  queue: ptr Sipsic[N, int]
  received: ptr array[ItemCount, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producerDone: ptr Atomic[bool]

proc sipsicProducer[N: static int](ctx: ptr SipsicThreadContext[N]) {.thread.} =
  for i in 1 .. ItemCount:
    while not ctx.queue[].push(i):
      discard
  ctx.producerDone[].store(true, moRelease)

proc sipsicConsumer[N: static int](ctx: ptr SipsicThreadContext[N]) {.thread.} =
  var consumed = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let val = item.get - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producerDone[].load(moAcquire):
      discard

suite "Legacy Sipsic - Single-threaded":
  test "capacity and fullness indicators":
    var q = initSipsic[8, int]()
    check(q.capacity == 8)
    check(q.empty == true)
    check(q.full == false)

  test "push and pop basic FIFO":
    var q = initSipsic[8, int]()
    for i in 1 .. 8:
      check(q.push(i) == true)
    check(q.full == true)
    check(q.push(999) == false) # overflow

    for i in 1 .. 8:
      let item = q.pop()
      check(item.isSome)
      check(item.get == i)
    check(q.empty == true)
    check(q.pop().isNone)

  test "batch push and batch pop":
    var q = initSipsic[8, int]()
    let remNone = q.push(@[10, 20, 30, 40])
    check(remNone.isNone)

    let popped = q.pop(3)
    check(popped.isSome)
    check(popped.get == @[10, 20, 30])

    let remOverflow = q.push(@[50, 60, 70, 80, 90, 100, 110, 120])
    check(remOverflow.isSome) # could only fit 7 more items

  test "ring wraparound integrity":
    var q = initSipsic[8, int]()
    for i in 1 .. 4:
      check(q.push(i) == true)
    check(q.pop().get == 1)
    check(q.pop().get == 2)
    # 2 items in queue (3, 4). Push 6 more to wrap ring.
    for i in 5 .. 10:
      check(q.push(i) == true)
    check(q.full == true)
    check(q.push(99) == false)

    var outSeq: seq[int] = @[]
    while not q.empty:
      let item = q.pop()
      if item.isSome:
        outSeq.add(item.get)
    check(outSeq == @[3, 4, 5, 6, 7, 8, 9, 10])

suite "Legacy Sipsic - Multi-threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)

  test "threaded high contention (N=16)":
    var queue = initSipsic[16, int]()
    var ctx = SipsicThreadContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
    )
    var prodThread, consThread: Thread[ptr SipsicThreadContext[16]]
    createThread(prodThread, sipsicProducer[16], addr ctx)
    createThread(consThread, sipsicConsumer[16], addr ctx)
    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "threaded normal capacity (N=64)":
    var queue = initSipsic[64, int]()
    var ctx = SipsicThreadContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
    )
    var prodThread, consThread: Thread[ptr SipsicThreadContext[64]]
    createThread(prodThread, sipsicProducer[64], addr ctx)
    createThread(consThread, sipsicConsumer[64], addr ctx)
    joinThread(prodThread)
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
