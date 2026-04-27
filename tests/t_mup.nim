## Shared test templates for multi-producer queues (Mupsic, Mupmuc).

when defined(posix):
  import posix # pthread_join, used by testMupGetProducerThrowsNoProducersAvailable

template testMupGetProducerAssigns*(queue: untyped) =
  let producer = queue.getProducer()
  check(producer.idx == 0)
  check(queue.producerThreadIds[0].acquire == getThreadId())
  for p in 1 ..< queue.producerCount:
    check(queue.producerThreadIds[p].acquire == 0)

template testMupGetProducerReusesAssigned*(queue: untyped) =
  discard queue.getProducer()
  let producer = queue.getProducer()
  check(producer.idx == 0)
  check(queue.producerThreadIds[0].acquire == getThreadId())
  for p in 1 ..< queue.producerCount:
    check(queue.producerThreadIds[p].acquire == 0)

template testMupGetProducerExplicitIndex*(queue: untyped) =
  for idx in 0 ..< queue.producerCount:
    check(queue.getProducer(idx).idx == idx)

template testMupGetProducerThrowsNoProducersAvailable*(queue: untyped) =
  proc assignProducer() {.thread.} =
    discard queue.getProducer()

  var threads: array[4, Thread[void]]
  for i in 0 .. 3:
    threads[i].createThread(assignProducer)
  # On POSIX, call `pthread_join` directly on the `sys` handle instead of
  # `joinThread(threads[i])`. Nim's `joinThread` takes its `Thread[T]`
  # argument by value, which the codegen emits as a memcpy of the whole
  # struct. While the worker is finishing up, `threadProcWrapper` writes
  # `thrd.core = nil` and `thrd.dataFn = nil` (system/threadimpl.nim:109-110),
  # and aarch64 TSAN flags that memcpy as a race against those final
  # stores. Reading only the `sys` field (set once at `createThread` and
  # never touched again) avoids the copy. On non-POSIX targets, fall back
  # to the standard `joinThread` API.
  when defined(posix):
    for i in 0 .. 3:
      discard pthread_join(threads[i].sys, nil)
  else:
    for i in 0 .. 3:
      joinThread(threads[i])
  expect NoProducersAvailableError:
    discard queue.getProducer()

template testMupPush*(queue: untyped) =
  check(queue.getProducer(0).push(1) == true)
  check(queue.getProducer(0).push(2) == true)
  queue.checkState(head = 0, reservedTail = 2)

  check(queue.getProducer(1).push(3) == true)
  check(queue.getProducer(1).push(4) == true)

  queue.checkState(head = 0, reservedTail = 4)

  check(queue.getProducer(2).push(5) == true)
  check(queue.getProducer(2).push(6) == true)

  queue.checkState(head = 0, reservedTail = 6)

  check(queue.getProducer(3).push(7) == true)
  check(queue.getProducer(3).push(8) == true)

  queue.checkState(head = 0, reservedTail = 8)

template testMupPushOverflow*(queue: untyped) =
  for i in 1 .. 8:
    discard queue.getProducer(0).push(i)
  check(queue.getProducer(0).push(9) == false)
  queue.checkState(head = 0, reservedTail = 8)

template testMupPushWrap*(queue: untyped) =
  for i in 1 .. 4:
    discard queue.getProducer(0).push(i)
  for i in 0 .. 1:
    when queue is Mupmuc:
      discard queue.getConsumer(i).pop()
    else:
      discard queue.pop()
  for i in 5 .. 10:
    check(queue.getProducer(0).push(i) == true)
  queue.checkState(head = 2, reservedTail = 10)

template testMupPushSeq*(queue: untyped) =
  check(queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8]).isNone)
  queue.checkState(head = 0, reservedTail = 8)

template testMupPushSeqOverflow*(queue: untyped) =
  let res =
    queue.getProducer(0).push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
  check(res.isSome)
  check(res.get == 8 .. 15)
  queue.checkState(head = 0, reservedTail = 8)

template testMupPushSeqWrap*(queue: untyped) =
  discard queue.getProducer(0).push(@[1, 2, 3, 4])
  for i in 0 .. 1:
    when queue is Mupmuc:
      discard queue.getConsumer(i).pop()
    else:
      discard queue.pop()
  var res = queue.getProducer(0).push(@[5, 6, 7, 8, 9, 10])
  check(res.isNone)
  queue.checkState(head = 2, reservedTail = 10)
