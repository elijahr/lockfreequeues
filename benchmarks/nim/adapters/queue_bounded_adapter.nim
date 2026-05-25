## Consolidated adapter for lockfreequeues' bounded `BQueue` generic.
## Replaces the 4 parallel `lockfreequeues_queue_bounded_*` adapters
## with a single type parameterized over `ccProd, ccCons, N, P, C, T`.
##
## v5.0.0 cascade Track D3.6.5; B.2.5 rewired from the legacy 10-param
## `Queue[..., rkNone, ...]` to the dedicated 6-param `BQueue`.
##
## **ST phantom retention.** Pre-B.2.5 the adapter carried an `ST`
## (`DeallocationStrategy`) phantom param to match the unified Queue's
## bounded shape. BQueue has no `ST` axis (deallocation strategy is an
## unbounded-only concern), but the bench harness call sites still pass
## an `ST` value through the adapter's type list. Keep `ST` as a
## tag-only phantom — it is consumed by the call-site type-list but
## never reaches BQueue itself.
##
## Dispatch:
##   - push: when `ccProd == ccSingle`, push goes through the queue
##     directly. When `ccProd == ccMulti`, push goes through the cached
##     `producer` slot acquired at construction.
##   - pop: mirror for `ccCons`.

import options
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import ../bench_common

type
  QueueBoundedAdapter*[
      ccProd, ccCons: static PinScopeCardinality;
      ST: static DeallocationStrategy;
      N, P, C: static int;
      T] = object
    ## `ST` is a tag-only phantom retained for call-site compatibility
    ## with the pre-B.2.5 adapter shape.
    queue*: ptr BQueue[T, ccProd, ccCons, N, P, C]
    when ccProd == ccMulti:
      producer: BQueueProducer[T, ccProd, ccCons, N, P, C]
    when ccCons == ccMulti:
      consumer: BQueueConsumer[T, ccProd, ccCons, N, P, C]

proc getProducer*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T], idx: int
): BQueueProducer[T, ccProd, ccCons, N, P, C] =
  a.queue[].getProducer(idx = idx)

proc getConsumer*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T], idx: int
): BQueueConsumer[T, ccProd, ccCons, N, P, C] =
  a.queue[].getConsumer(idx = idx)

proc makeQueueBoundedAdapter*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    capacity: int = N
): QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T] =
  doAssert capacity == N, "capacity must equal static N"
  result.queue = create(BQueue[T, ccProd, ccCons, N, P, C])
  # wasMoved before the deref-assign: `create` zero-fills but the BQueue
  # typestate `=destroy` is still untracked-untrusted by ARC/ORC, so the
  # `result.queue[] = ...` would otherwise run `=destroy` on uninitialized
  # storage. wasMoved marks the slot as moved-from so no destructor fires.
  wasMoved(result.queue[])
  result.queue[] = q_mod.newBQueue[T, ccProd, ccCons, N, P, C]()
  when ccProd == ccMulti:
    result.producer = result.queue[].getProducer(idx = 0)
  when ccCons == ccMulti:
    result.consumer = result.queue[].getConsumer(idx = 0)

proc cleanup*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T]
) =
  # Reset the cached producer/consumer views BEFORE deallocating the queue
  # they borrow from. Each view holds a pointer into `a.queue[]` and has a
  # typestate `=destroy` that runs at adapter scope exit (after this proc
  # returns). Without resetting them here, those destructors would touch
  # freed memory (use-after-free). reset() runs each view's `=destroy` now,
  # while the queue is still alive, and leaves the field in a moved-from
  # state whose later scope-exit destructor is a no-op.
  when ccProd == ccMulti:
    reset(a.producer)
  when ccCons == ccMulti:
    reset(a.consumer)
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T], item: T
): PushResult =
  when ccProd == ccSingle:
    if a.queue[].push(item): prSuccess else: prFull
  else:
    if a.producer.push(item): prSuccess else: prFull

proc pop*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T]
): PopResult[T] =
  when ccCons == ccSingle:
    let r = a.queue[].pop()
  else:
    let r = a.consumer.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)

proc name*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T]
): string =
  "lockfreequeues/BQueue[" & $ccProd & "," & $ccCons & "," &
    $N & "," & $P & "," & $C & "]"
