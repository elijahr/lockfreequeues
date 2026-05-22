## Adapter for lockfreequeues Sipmuc-equivalent (bounded SPMC, single
## producer + N consumers).
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
##
## v5.0.0 cascade: the legacy `Sipmuc[N, C, T]` type was deleted in
## 3.3.7 in favour of the unified `Queue[T, ccSingle, ccMulti, stEager,
## rkNone, N, 0, C, 0, 0]` generic. The adapter surface (`push`, `pop`,
## `getConsumer`, the factory) is preserved verbatim.

import options
import lockfreequeues
import ../bench_common

const topologiesSupported* = {tMpmc}
  ## Per design 2.2, Sipmuc lives under `mpmc` with shapes restricted
  ## to `1p<C>c`. Exported here for PR 3 Task 3.11 consumption; PR 0
  ## ships the type but does not yet read it.

type
  SipmucQueue*[N, C: static int, T] =
    Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0]
  SipmucConsumerView*[N, C: static int, T] =
    QueueConsumer[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0, 0]

  LockfreequeuesSipmucAdapter*[N, C: static int, T] = object
    queue*: ptr SipmucQueue[N, C, T]
      ## Exported so multi-consumer shapes can register their own
      ## per-thread consumer via `adapter.getConsumer(idx)` (or, for
      ## advanced callers, `adapter.queue[].getConsumer(idx)` directly).
      ## See the `getConsumer` proc below for the documented entry point.
    consumer: SipmucConsumerView[N, C, T]
      ## Pre-built consumer for the 1C shape. Multi-consumer shapes
      ## bypass this slot and call `getConsumer(idx)` per-thread.

proc getConsumer*[N, C: static int, T](
    a: var LockfreequeuesSipmucAdapter[N, C, T], idx: int
): SipmucConsumerView[N, C, T] =
  ## Acquire a per-thread consumer from the underlying Sipmuc-equiv queue.
  ## Multi-consumer benchmark shapes (`1p<C>c` for C > 1) MUST call
  ## this on each consumer thread with a unique `idx in 0 ..< C`;
  ## sharing a single `Consumer` across threads is unsafe.
  a.queue[].getConsumer(idx = idx)

proc makeLockfreequeuesSipmucAdapter*[N, C: static int, T](
    capacity: int = N
): LockfreequeuesSipmucAdapter[N, C, T] =
  ## Allocate and initialize a Sipmuc-equiv Queue[N, C, T]. `capacity`
  ## must equal N (the static parameter); the runtime arg exists only
  ## to satisfy the adapter convention's uniform factory shape across
  ## bounded queues.
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(SipmucQueue[N, C, T])
  result.queue[] = initQueue[T, ccSingle, ccMulti, stEager, N, 0, C]()
  # Pre-allocate consumer 0; bench code that drives multiple consumers
  # registers its own per-thread Consumer via getConsumer(idx = i).
  result.consumer = result.queue[].getConsumer(idx = 0)

proc cleanup*[N, C: static int, T](
    a: var LockfreequeuesSipmucAdapter[N, C, T]
) =
  if a.queue != nil:
    reset(a.queue[])
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
