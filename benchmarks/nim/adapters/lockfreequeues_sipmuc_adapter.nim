## Adapter for lockfreequeues Sipmuc (bounded SPMC, single producer + N
## consumers).
##
## Sipmuc benches live under the project's `mpmc` topology axis (single
## producer is just N=1 of multi-producer); shapes are `1p<C>c`.
##
## This adapter exposes the bench_common.nim BenchAdapter shape:
##   - `push(item: uint64): PushResult`  -> returns prFull on a full queue.
##   - `pop(): PopResult[uint64]`        -> reads from the queue's
##                                         *single* consumer slot since
##                                         the bench harness drives a
##                                         single consumer thread for the
##                                         smoke topology. Multi-consumer
##                                         shapes (1p2c, 1p4c) are added
##                                         in PR 2 via the topology-split
##                                         binaries.

import options
import lockfreequeues/sipmuc
import ../bench_common

const topologiesSupported* = {tMpmc}
  ## Per design 2.2, Sipmuc lives under `mpmc` with shapes restricted
  ## to `1p<C>c`. Exported here for PR 3 Task 3.11 consumption; PR 0
  ## ships the type but does not yet read it.

type
  LockfreequeuesSipmucAdapter*[N, C: static int, T] = object
    queue: ptr Sipmuc[N, C, T]
    consumer: Consumer[N, C, T]

proc makeLockfreequeuesSipmucAdapter*[N, C: static int, T](
    capacity: int = N
): LockfreequeuesSipmucAdapter[N, C, T] =
  ## Allocate and initialize a Sipmuc[N, C, T]. `capacity` must equal N
  ## (the static parameter); the runtime arg exists only to satisfy the
  ## adapter convention's uniform factory shape across bounded queues.
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(Sipmuc[N, C, T])
  result.queue[] = initSipmuc[N, C, T]()
  # Pre-allocate consumer 0; bench code that drives multiple consumers
  # registers its own per-thread Consumer via getConsumer(idx = i).
  result.consumer = result.queue[].getConsumer(idx = 0)

proc cleanup*[N, C: static int, T](
    a: var LockfreequeuesSipmucAdapter[N, C, T]
) =
  if a.queue != nil:
    dealloc(a.queue)
    a.queue = nil

proc push*[N, C: static int, T](
    a: var LockfreequeuesSipmucAdapter[N, C, T], item: T
): PushResult =
  if a.queue[].push(item): prSuccess else: prFull

proc pop*[N, C: static int, T](
    a: var LockfreequeuesSipmucAdapter[N, C, T]
): PopResult[T] =
  let r = a.consumer.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
