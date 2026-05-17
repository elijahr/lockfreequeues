## Consolidated adapter for lockfreequeues' unified `Queue` generic at
## the bounded (rkNone) cardinality grid. Replaces the 4 parallel
## `lockfreequeues_queue_bounded_{sipsic,mupsic,sipmuc,mupmuc}_adapter.nim`
## files added in Track D3.6 with a single type parameterized over
## `ccProd, ccCons, ST, N, P, C, T` per the cascade-mapping table
## (D-early §4).
##
## v5.0.0 cascade Track D3.6.5.
##
## Dispatch:
##   - push: when `ccProd == ccSingle`, push goes through the queue
##     directly (`q.push(item)`). When `ccProd == ccMulti`, push goes
##     through the cached `producer` slot (slot 0) acquired at
##     construction; multi-producer bench shapes register additional
##     producers per-thread via `adapter.getProducer(idx = i)`.
##   - pop: mirror for `ccCons`. When `ccCons == ccSingle`, pop on the
##     queue. When `ccCons == ccMulti`, pop on the cached `consumer`
##     slot (slot 0).
##
## All Queue type parameters are required at the call site (P/C take
## sentinel value 0 when the cardinality is `ccSingle`), to keep the
## generic parameter list aligned with `Queue[T, ccProd, ccCons, ST,
## rkNone, N, P, C, 0, 0]`.

import options
import lockfreequeues/queue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import ../bench_common

type
  QueueBoundedAdapter*[
      ccProd, ccCons: static PinScopeCardinality;
      ST: static DeallocationStrategy;
      N, P, C: static int;
      T] = object
    queue*: ptr Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0]
    when ccProd == ccMulti:
      producer: QueueProducer[T, ccProd, ccCons, ST, rkNone,
                              N, P, C, 0, 0]
    when ccCons == ccMulti:
      consumer: QueueConsumer[T, ccProd, ccCons, ST, rkNone,
                              N, P, C, 0, 0]

proc getProducer*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T], idx: int
): QueueProducer[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0] =
  ## Acquire a per-thread producer (only meaningful when
  ## `ccProd == ccMulti`; for ccSingle the queue is the producer).
  a.queue[].getProducer(idx = idx)

proc getConsumer*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    a: var QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T], idx: int
): QueueConsumer[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0] =
  ## Acquire a per-thread consumer (only meaningful when
  ## `ccCons == ccMulti`; for ccSingle the queue is the consumer).
  a.queue[].getConsumer(idx = idx)

proc makeQueueBoundedAdapter*[
    ccProd, ccCons: static PinScopeCardinality;
    ST: static DeallocationStrategy;
    N, P, C: static int;
    T](
    capacity: int = N
): QueueBoundedAdapter[ccProd, ccCons, ST, N, P, C, T] =
  doAssert capacity == N, "capacity must equal static N"
  result.queue =
    create(Queue[T, ccProd, ccCons, ST, rkNone, N, P, C, 0, 0])
  result.queue[] =
    q_mod.initQueue[T, ccProd, ccCons, ST, N, P, C]()
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
  "lockfreequeues/Queue[" & $ccProd & "," & $ccCons & ",rkNone," &
    $N & "," & $P & "," & $C & "]"
