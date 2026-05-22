## Adapter for lockfreequeues Mupsic-equivalent (bounded MPSC,
## multi-producer + single consumer).
##
## Topology: `mpsc` with shapes `<P>p1c`. Multi-producer shapes drive a
## per-thread `Producer` via `queue.getProducer(idx)` on each producer
## thread. The single-consumer pop path goes through the queue object
## directly.
##
## v5.0.0 cascade: the legacy `Mupsic[N, P, T]` type was deleted in
## 3.3.7 in favour of the unified `Queue[T, ccMulti, ccSingle, stEager,
## rkNone, N, P, 0, 0, 0]` generic. The adapter surface (`push`, `pop`,
## `getProducer`, the factory) is preserved verbatim.

import options
import lockfreequeues
import ../bench_common

const topologiesSupported* = {tMpsc}

type
  MupsicQueue*[N, P: static int, T] =
    Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]
  MupsicProducerView*[N, P: static int, T] =
    QueueProducer[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0, 0]

  LockfreequeuesMupsicAdapter*[N, P: static int, T] = object
    queue*: ptr MupsicQueue[N, P, T]
      ## Exported so multi-producer shapes can register their own
      ## per-thread producer via `adapter.getProducer(idx)` (or, for
      ## advanced callers, `adapter.queue[].getProducer(idx)` directly).
      ## See the `getProducer` proc below for the documented entry point.
    producer: MupsicProducerView[N, P, T]
      ## Pre-built producer for the 1P shape. Multi-producer shapes
      ## bypass this slot and call `getProducer(idx)` per-thread.

proc getProducer*[N, P: static int, T](
    a: var LockfreequeuesMupsicAdapter[N, P, T], idx: int
): MupsicProducerView[N, P, T] =
  ## Acquire a per-thread producer from the underlying Mupsic-equiv queue.
  ## Multi-producer benchmark shapes (`<P>p1c` for P > 1) MUST call
  ## this on each producer thread with a unique `idx in 0 ..< P`;
  ## sharing a single `Producer` across threads is unsafe.
  a.queue[].getProducer(idx = idx)

proc makeLockfreequeuesMupsicAdapter*[N, P: static int, T](
    capacity: int = N
): LockfreequeuesMupsicAdapter[N, P, T] =
  ## Allocate and initialize a Mupsic-equiv Queue[N, P, T]. The pre-built
  ## `producer` slot lets the smoke / 1p1c shape drive push from the
  ## calling thread; multi-producer shapes register additional producers
  ## per-thread via `queue.getProducer(idx = i)`.
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(MupsicQueue[N, P, T])
  result.queue[] = initQueue[T, ccMulti, ccSingle, stEager, N, P, 0]()
  result.producer = result.queue[].getProducer(idx = 0)

proc cleanup*[N, P: static int, T](
    a: var LockfreequeuesMupsicAdapter[N, P, T]
) =
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[N, P: static int, T](
    a: var LockfreequeuesMupsicAdapter[N, P, T], item: T
): PushResult =
  if a.producer.push(item): prSuccess else: prFull

proc pop*[N, P: static int, T](
    a: var LockfreequeuesMupsicAdapter[N, P, T]
): PopResult[T] =
  let r = a.queue[].pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
