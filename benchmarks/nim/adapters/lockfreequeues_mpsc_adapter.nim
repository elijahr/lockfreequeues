## Adapter for lockfreequeues Mpsc-equivalent (bounded MPSC,
## multi-producer + single consumer).
##
## Topology: `mpsc` with shapes `<P>p1c`. Multi-producer shapes drive a
## per-thread `Producer` via `queue.getProducer(idx)` on each producer
## thread. The single-consumer pop path goes through the queue object
## directly.
##
## The legacy `Mpsc[N, P, T]` type has been removed in favour of the
## unified `Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P, 0, 0,
## 0]` generic. The adapter surface (`push`, `pop`, `getProducer`,
## the factory) is preserved verbatim.

import options
import lockfreequeues
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import ../bench_common

const topologiesSupported* = {tMpsc}

type
  MpscQueue*[N, P: static int, T] = BQueue[T, ccMulti, ccSingle, N, P, 0]
  MpscProducerView*[N, P: static int, T] =
    Bound[T, AnyThreadTag, BQueue[T, ccMulti, ccSingle, N, P, 0]]

  LockfreequeuesMpscAdapter*[N, P: static int, T] = object
    queue*: ptr MpscQueue[N, P, T]
      ## Exported so multi-producer shapes can register their own
      ## per-thread producer via `adapter.getProducer(idx)` (or, for
      ## advanced callers, `adapter.queue[].getProducer(idx)` directly).
      ## See the `getProducer` proc below for the documented entry point.
    producer: MpscProducerView[N, P, T]
      ## Pre-built producer for the 1P shape. Multi-producer shapes
      ## bypass this slot and call `getProducer(idx)` per-thread.

proc getProducer*[N, P: static int, T](
    a: var LockfreequeuesMpscAdapter[N, P, T], idx: int
): MpscProducerView[N, P, T] =
  ## Acquire a per-thread producer from the underlying Mpsc-equiv queue.
  ## Multi-producer benchmark shapes (`<P>p1c` for P > 1) MUST call
  ## this on each producer thread with a unique `idx in 0 ..< P`;
  ## sharing a single `Producer` across threads is unsafe.
  a.queue[].getProducerHere(idx = idx)

proc makeLockfreequeuesMpscAdapter*[N, P: static int, T](
    capacity: int = N
): LockfreequeuesMpscAdapter[N, P, T] =
  ## Allocate and initialize a Mpsc-equiv Queue[N, P, T]. The pre-built
  ## `producer` slot lets the smoke / 1p1c shape drive push from the
  ## calling thread; multi-producer shapes register additional producers
  ## per-thread via `queue.getProducerHere(idx = i)`.
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(MpscQueue[N, P, T])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.queue[] = ...` would run the BQueue typestate
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.queue[])
  result.queue[] = newBQueue[T, ccMulti, ccSingle, N, P, 0]()
  result.producer = result.queue[].getProducerHere(idx = 0)

proc cleanup*[N, P: static int, T](a: var LockfreequeuesMpscAdapter[N, P, T]) =
  # Reset the cached producer view BEFORE deallocating the queue it borrows
  # from. The view holds a pointer into `a.queue[]` and carries a typestate
  # `=destroy` that would otherwise run at adapter scope exit (after this
  # proc returns and the queue is freed), touching freed memory. reset()
  # runs its destructor now, while the queue is still valid.
  if a.queue != nil:
    reset(a.producer)
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[N, P: static int, T](
    a: var LockfreequeuesMpscAdapter[N, P, T], item: T
): PushResult =
  if a.producer.push(item): prSuccess else: prFull

proc pop*[N, P: static int, T](
    a: var LockfreequeuesMpscAdapter[N, P, T]
): PopResult[T] =
  let r = a.queue[].pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
