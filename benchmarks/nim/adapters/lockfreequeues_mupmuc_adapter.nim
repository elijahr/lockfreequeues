## Adapter for lockfreequeues Mupmuc (bounded MPMC).
##
## Renamed from `lockfreequeues_mupmuc.nim` in PR 0 Task 0.9 per design
## section 2.2. `topologiesSupported` is exported here for PR 3
## Task 3.11.
##
## Note: Mupmuc requires using Producer/Consumer objects for push/pop.
## This adapter manages those internally for single-threaded testing.
## For multi-threaded benchmarks, use getProducer/getConsumer directly.

import options
import lockfreequeues/mupmuc
import ../bench_common

const topologiesSupported*: set[Topology] = {tMpmc}

type
  MupmucAdapter*[N: static int, T] = object
    queue: ptr Mupmuc[N, 1, 1, T]
    producer: MupmucProducer[N, 1, 1, T]
    consumer: Consumer[N, 1, 1, T]

proc initMupmucAdapter*[N: static int, T](): MupmucAdapter[N, T] =
  result.queue = create(Mupmuc[N, 1, 1, T])
  result.queue[] = initMupmuc[N, 1, 1, T]()
  # Use idx parameter to manually assign producer/consumer for single-threaded
  # use AND for multi-threaded ping-pong (bench_common.runLatencyHarness):
  # `getProducer(idx = 0)` skips the threadId-based registration path, so the
  # returned object is safe to call from any thread for the bench's 1P/1C
  # smoke shape (only one producer/consumer slot exists, and the underlying
  # Vyukov per-slot CAS protocol is fully concurrent-safe).
  result.producer = result.queue[].getProducer(idx = 0)
  result.consumer = result.queue[].getConsumer(idx = 0)

proc deinitMupmucAdapter*[N: static int, T](a: var MupmucAdapter[N, T]) =
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc cleanup*[N: static int, T](a: var MupmucAdapter[N, T]) =
  ## Alias for `deinitMupmucAdapter` matching the lockfreequeues bounded
  ## adapter naming convention. Lets the bench harness drop the queue
  ## via a uniform `cleanup(queue)` mixin call.
  deinitMupmucAdapter(a)

proc push*[N: static int, T](a: var MupmucAdapter[N, T], item: T): PushResult =
  if a.producer.push(item): prSuccess else: prFull

proc pop*[N: static int, T](a: var MupmucAdapter[N, T]): PopResult[T] =
  let item = a.consumer.pop()
  if item.isSome:
    PopResult[T](success: true, value: item.get)
  else:
    PopResult[T](success: false)

proc name*[N: static int, T](a: MupmucAdapter[N, T]): string =
  "lockfreequeues/Mupmuc[" & $N & "]"
