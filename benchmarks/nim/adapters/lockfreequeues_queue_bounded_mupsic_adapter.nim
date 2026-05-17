## Adapter for lockfreequeues' unified `Queue` generic in the bounded
## MPSC cardinality `Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P,
## 0, 0, 0]`. Mirrors `lockfreequeues_mupsic_adapter.nim` so B3 can
## compute a parity delta between the legacy `Mupsic[N, P, T]` and the
## new unified Queue under the same harness.
##
## v5.0.0 cascade Track D3.6. Track D3.6.5 consolidates.
##
## Multi-producer shapes (`<P>p1c` for P > 1) acquire one
## `QueueProducer` per thread via `adapter.getProducer(idx)`, mirroring
## the legacy Mupsic adapter contract.

import options
import lockfreequeues
import lockfreequeues/queue as q_mod
import ../bench_common

const topologiesSupported* = {tMpsc}

type
  QueueBoundedMupsicAdapter*[N, P: static int, T] = object
    queue*: ptr Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]
    producer: QueueProducer[T, ccMulti, ccSingle, stEager, rkNone,
                            N, P, 0, 0, 0]

proc getProducer*[N, P: static int, T](
    a: var QueueBoundedMupsicAdapter[N, P, T], idx: int
): QueueProducer[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0] =
  a.queue[].getProducer(idx = idx)

proc makeQueueBoundedMupsicAdapter*[N, P: static int, T](
    capacity: int = N
): QueueBoundedMupsicAdapter[N, P, T] =
  doAssert capacity == N, "capacity must equal static N"
  result.queue =
    create(Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0])
  result.queue[] =
    q_mod.initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()
  result.producer = result.queue[].getProducer(idx = 0)

proc cleanup*[N, P: static int, T](
    a: var QueueBoundedMupsicAdapter[N, P, T]
) =
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[N, P: static int, T](
    a: var QueueBoundedMupsicAdapter[N, P, T], item: T
): PushResult =
  if a.producer.push(item): prSuccess else: prFull

proc pop*[N, P: static int, T](
    a: var QueueBoundedMupsicAdapter[N, P, T]
): PopResult[T] =
  let r = a.queue[].pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
