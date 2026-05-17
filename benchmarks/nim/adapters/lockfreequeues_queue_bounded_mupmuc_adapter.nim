## Adapter for lockfreequeues' unified `Queue` generic in the bounded
## MPMC cardinality `Queue[T, ccMulti, ccMulti, stEager, rkNone, N, P,
## C, 0, 0]`. Mirrors `lockfreequeues_mupmuc_adapter.nim`.
##
## v5.0.0 cascade Track D3.6. Track D3.6.5 consolidates.
##
## Uses the pre-allocated Producer/Consumer at slot 0 for the 1p1c
## smoke shape; multi-producer/multi-consumer shapes register their
## own per-thread Producer / Consumer via the legacy adapter pattern.

import options
import lockfreequeues
import lockfreequeues/queue as q_mod
import ../bench_common

const topologiesSupported*: set[Topology] = {tMpmc}

type
  QueueBoundedMupmucAdapter*[N: static int, T] = object
    queue: ptr Queue[T, ccMulti, ccMulti, stEager, rkNone, N, 1, 1, 0, 0]
    producer: QueueProducer[T, ccMulti, ccMulti, stEager, rkNone,
                            N, 1, 1, 0, 0]
    consumer: QueueConsumer[T, ccMulti, ccMulti, stEager, rkNone,
                            N, 1, 1, 0, 0]

proc initQueueBoundedMupmucAdapter*[N: static int, T]():
    QueueBoundedMupmucAdapter[N, T] =
  result.queue =
    create(Queue[T, ccMulti, ccMulti, stEager, rkNone, N, 1, 1, 0, 0])
  result.queue[] =
    q_mod.initQueue[T, ccMulti, ccMulti, stEager, N, 1, 1]()
  result.producer = result.queue[].getProducer(idx = 0)
  result.consumer = result.queue[].getConsumer(idx = 0)

proc deinitQueueBoundedMupmucAdapter*[N: static int, T](
    a: var QueueBoundedMupmucAdapter[N, T]
) =
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc cleanup*[N: static int, T](
    a: var QueueBoundedMupmucAdapter[N, T]
) =
  ## Alias for `deinitQueueBoundedMupmucAdapter` matching the bounded
  ## adapter naming convention (uniform `cleanup(queue)` mixin).
  deinitQueueBoundedMupmucAdapter(a)

proc push*[N: static int, T](
    a: var QueueBoundedMupmucAdapter[N, T], item: T
): PushResult =
  if a.producer.push(item): prSuccess else: prFull

proc pop*[N: static int, T](
    a: var QueueBoundedMupmucAdapter[N, T]
): PopResult[T] =
  let item = a.consumer.pop()
  if item.isSome:
    PopResult[T](success: true, value: item.get)
  else:
    PopResult[T](success: false)

proc name*[N: static int, T](a: QueueBoundedMupmucAdapter[N, T]): string =
  "lockfreequeues/Queue[ccMulti,ccMulti,rkNone," & $N & "]"
