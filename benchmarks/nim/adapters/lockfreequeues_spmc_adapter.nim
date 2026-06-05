## Adapter for lockfreequeues Spmc-equivalent (bounded SPMC, single
## producer + N consumers).
##
## Spmc benches live under the project's `mpmc` topology axis (single
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
## The legacy `Spmc[N, C, T]` type has been removed in favour of the
## unified `Queue[T, ccSingle, ccMulti, stEager, rkNone, N, 0, C, 0,
## 0]` generic. The adapter surface (`push`, `pop`, `getConsumer`,
## the factory) is preserved verbatim.

import options
import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import ../bench_common

const topologiesSupported* = {tMpmc}
  ## Spmc lives under the `mpmc` topology with shapes restricted to
  ## `1p<C>c`. Exported here for the bench-driver registry.

type
  SpmcQueue*[N, C: static int, T] = BQueue[T, ccSingle, ccMulti, N, 0, C]
  SpmcConsumerView*[N, C: static int, T] =
    Bound[T, AnyThreadTag, BQueue[T, ccSingle, ccMulti, N, 0, C]]

  LockfreequeuesSpmcAdapter*[N, C: static int, T] = object
    queue*: ptr SpmcQueue[N, C, T]
      ## Exported so multi-consumer shapes can register their own
      ## per-thread consumer via `adapter.getConsumer(idx)` (or, for
      ## advanced callers, `adapter.queue[].getConsumer(idx)` directly).
      ## See the `getConsumer` proc below for the documented entry point.
    consumer: SpmcConsumerView[N, C, T]
      ## Pre-built consumer for the 1C shape. Multi-consumer shapes
      ## bypass this slot and call `getConsumer(idx)` per-thread.

proc getConsumer*[N, C: static int, T](
    a: var LockfreequeuesSpmcAdapter[N, C, T], idx: int
): SpmcConsumerView[N, C, T] =
  ## Acquire a per-thread consumer from the underlying Spmc-equiv queue.
  ## Multi-consumer benchmark shapes (`1p<C>c` for C > 1) MUST call
  ## this on each consumer thread with a unique `idx in 0 ..< C`;
  ## sharing a single `Consumer` across threads is unsafe.
  a.queue[].getConsumerHere(idx = idx)

proc makeLockfreequeuesSpmcAdapter*[N, C: static int, T](
    capacity: int = N
): LockfreequeuesSpmcAdapter[N, C, T] =
  ## Allocate and initialize a Spmc-equiv Queue[N, C, T]. `capacity`
  ## must equal N (the static parameter); the runtime arg exists only
  ## to satisfy the adapter convention's uniform factory shape across
  ## bounded queues.
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(SpmcQueue[N, C, T])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.queue[] = ...` would run the BQueue typestate
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.queue[])
  result.queue[] = newBQueue[T, ccSingle, ccMulti, N, 0, C]()
  # Pre-allocate consumer 0; bench code that drives multiple consumers
  # registers its own per-thread Consumer via getConsumer(idx = i).
  result.consumer = result.queue[].getConsumerHere(idx = 0)

proc cleanup*[N, C: static int, T](a: var LockfreequeuesSpmcAdapter[N, C, T]) =
  # Reset the cached consumer view BEFORE deallocating the queue it borrows
  # from. The view holds a pointer into `a.queue[]` and carries a typestate
  # `=destroy` that would otherwise run at adapter scope exit (after this
  # proc returns and the queue is freed), touching freed memory. reset()
  # runs its destructor now, while the queue is still valid.
  if a.queue != nil:
    reset(a.consumer)
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[N, C: static int, T](
    a: var LockfreequeuesSpmcAdapter[N, C, T], item: T
): PushResult =
  if a.queue[].push(item): prSuccess else: prFull

proc pop*[N, C: static int, T](
    a: var LockfreequeuesSpmcAdapter[N, C, T]
): PopResult[T] =
  let r = a.consumer.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
