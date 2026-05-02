## Adapter for lockfreequeues Mupsic (bounded MPSC, multi-producer +
## single consumer).
##
## Topology: `mpsc` with shapes `<P>p1c`. Multi-producer shapes drive a
## per-thread `Producer` via `queue.getProducer(idx)` on each producer
## thread. The single-consumer pop path goes through the queue object
## directly.

import options
import lockfreequeues/mupsic
import ../bench_common

const topologiesSupported* = {tMpsc}

type
  LockfreequeuesMupsicAdapter*[N, P: static int, T] = object
    queue: ptr Mupsic[N, P, T]
    producer: Producer[N, P, T]

proc makeLockfreequeuesMupsicAdapter*[N, P: static int, T](
    capacity: int = N
): LockfreequeuesMupsicAdapter[N, P, T] =
  ## Allocate and initialize a Mupsic[N, P, T]. The pre-built `producer`
  ## slot lets the smoke / 1p1c shape drive push from the calling
  ## thread; multi-producer shapes register additional producers
  ## per-thread via `queue.getProducer(idx = i)`.
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(Mupsic[N, P, T])
  result.queue[] = initMupsic[N, P, T]()
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
