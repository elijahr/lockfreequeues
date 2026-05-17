## Adapter for lockfreequeues' unified `Queue` generic in the bounded
## SPMC cardinality `Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0,
## C, 0, 0]`. Mirrors `lockfreequeues_sipmuc_adapter.nim`.
##
## v5.0.0 cascade Track D3.6. Track D3.6.5 consolidates.
##
## Multi-consumer shapes (`1p<C>c` for C > 1) acquire one
## `QueueConsumer` per thread via `adapter.getConsumer(idx)`.

import options
import lockfreequeues
import lockfreequeues/queue as q_mod
import ../bench_common

const topologiesSupported* = {tMpmc}
  ## Per design 2.2, the SPMC bench lives under the `mpmc` topology
  ## axis with shapes restricted to `1p<C>c`.

type
  QueueBoundedSipmucAdapter*[N, C: static int, T] = object
    queue*: ptr Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0]
    consumer: QueueConsumer[T, ccSingle, ccMulti, stEager, rkNone,
                            N, 0, C, 0, 0]

proc getConsumer*[N, C: static int, T](
    a: var QueueBoundedSipmucAdapter[N, C, T], idx: int
): QueueConsumer[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0] =
  a.queue[].getConsumer(idx = idx)

proc makeQueueBoundedSipmucAdapter*[N, C: static int, T](
    capacity: int = N
): QueueBoundedSipmucAdapter[N, C, T] =
  doAssert capacity == N, "capacity must equal static N"
  result.queue =
    create(Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0])
  result.queue[] =
    q_mod.initQueue[T, ccSingle, ccMulti, stEager, N, 0, C]()
  result.consumer = result.queue[].getConsumer(idx = 0)

proc cleanup*[N, C: static int, T](
    a: var QueueBoundedSipmucAdapter[N, C, T]
) =
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[N, C: static int, T](
    a: var QueueBoundedSipmucAdapter[N, C, T], item: T
): PushResult =
  if a.queue[].push(item): prSuccess else: prFull

proc pop*[N, C: static int, T](
    a: var QueueBoundedSipmucAdapter[N, C, T]
): PopResult[T] =
  let r = a.consumer.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
