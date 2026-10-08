import options
import unittest2
import lockfreequeues
import lockfreequeues/atomic_dsl

const
  ItemCount = 10000
  ConsumerCount = 4

type
  SipmucThreadContext[N: static int] = object
    queue: ptr Sipmuc[N, ConsumerCount, int]
    received: ptr array[ItemCount, Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    producerDone: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]

proc sipmucProducer[N: static int](ctx: ptr SipmucThreadContext[N]) {.thread.} =
  for i in 1 .. ItemCount:
    while not ctx.queue[].push(i):
      discard
  ctx.producerDone[].store(true, moRelease)

proc sipmucConsumer[N: static int](ctx: ptr SipmucThreadContext[N]) {.thread.} =
  var c = ctx.queue[].getConsumer()
  while true:
    let item = c.pop()
    if item.isSome:
      let val = item.get - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ItemCount:
        break
    elif ctx.producerDone[].load(moAcquire):
      if ctx.totalConsumed[].load(moRelaxed) >= ItemCount:
        break

suite "Legacy Sipmuc - Single-threaded":
  test "capacity and consumerCount metadata":
    var q = initSipmuc[8, 4, int]()
    check(q.capacity == 8)
    check(q.consumerCount == 4)
    check(q.empty == true)
    check(q.full == false)

  test "push and consumer pop FIFO":
    var q = initSipmuc[8, 4, int]()
    for i in 1 .. 8:
      check(q.push(i) == true)
    check(q.full == true)
    check(q.push(999) == false)

    var c0 = q.getConsumer(0)
    for i in 1 .. 8:
      let item = c0.pop()
      check(item.isSome)
      check(item.get == i)
    check(q.empty == true)
    check(c0.pop().isNone)

  test "multiple consumers interleaving":
    var q = initSipmuc[8, 2, int]()
    var c0 = q.getConsumer(0)
    var c1 = q.getConsumer(1)

    check(q.push(10) == true)
    check(q.push(20) == true)
    check(q.push(30) == true)
    check(q.push(40) == true)

    check(c0.pop().get == 10)
    check(c1.pop().get == 20)
    check(c0.pop().get == 30)
    check(c1.pop().get == 40)
    check(q.empty == true)

  test "batch push and batch pop":
    var q = initSipmuc[8, 2, int]()
    let rem = q.push(@[100, 200, 300, 400])
    check(rem.isNone)

    var c0 = q.getConsumer(0)
    let popped = c0.pop(4)
    check(popped.isSome)
    check(popped.get == @[100, 200, 300, 400])
    check(q.empty == true)

suite "Legacy Sipmuc - Multi-threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producerDone: Atomic[bool]
    totalConsumed: Atomic[int]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producerDone.store(false, moRelaxed)
    totalConsumed.store(0, moRelaxed)

  test "threaded high contention (N=16, C=4)":
    var queue = initSipmuc[16, ConsumerCount, int]()
    var ctx = SipmucThreadContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed,
    )

    var prodThread: Thread[ptr SipmucThreadContext[16]]
    var consThreads: array[ConsumerCount, Thread[ptr SipmucThreadContext[16]]]

    createThread(prodThread, sipmucProducer[16], addr ctx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], sipmucConsumer[16], addr ctx)

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "threaded normal capacity (N=64, C=4)":
    var queue = initSipmuc[64, ConsumerCount, int]()
    var ctx = SipmucThreadContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producerDone: addr producerDone,
      totalConsumed: addr totalConsumed,
    )

    var prodThread: Thread[ptr SipmucThreadContext[64]]
    var consThreads: array[ConsumerCount, Thread[ptr SipmucThreadContext[64]]]

    createThread(prodThread, sipmucProducer[64], addr ctx)
    for i in 0 ..< ConsumerCount:
      createThread(consThreads[i], sipmucConsumer[64], addr ctx)

    joinThread(prodThread)
    for i in 0 ..< ConsumerCount:
      joinThread(consThreads[i])

    check(not duplicateFound.load(moRelaxed))
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
