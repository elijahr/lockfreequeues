## Adapter for lockfreequeues UnboundedSipmuc (unbounded SPMC, single
## producer + N consumers).
##
## Topology: `mpmc_unbounded` with shapes `1p<C>c`. UnboundedSipmuc
## requires a `DebraManager` for epoch-based segment reclamation;
## consumers register against the manager and obtain a `Consumer` via
## `queue.getConsumer(handle)` ON THEIR OWN THREAD.
##
## This adapter owns the queue, the manager, and a pre-registered
## consumer-0 handle for the smoke / 1p1c shape. Multi-consumer shapes
## (1p2c, 1p4c) register additional consumer handles per-thread inside
## the bench harness.

import lockfreequeues/unbounded_sipmuc
import debra
import options
import ../bench_common

const topologiesSupported* = {tMpmcUnbounded}

type LockfreequeuesUnboundedSipmucAdapter*[S: static int, T;
                                            MaxThreads: static int] = object
  ## Manager is heap-pointer because UnboundedSipmuc takes a `ptr
  ## DebraManager` constructor argument (the queue stores the pointer
  ## into shared retire state). Queue is inline because heap-pointer
  ## storage on a generic destructor-bearing type triggers a Nim 2.2.6
  ## codegen bug from this generic adapter site.
  manager*: ptr DebraManager[MaxThreads]
  queue*: UnboundedSipmuc[S, T, MaxThreads]
  consumer0Handle*: ThreadHandle[MaxThreads]
  consumer0*: Consumer[S, T, MaxThreads]

proc makeLockfreequeuesUnboundedSipmucAdapter*[S: static int, T;
                                                MaxThreads: static int](
    capacity: int = 0    # ignored for unbounded
): LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads] =
  result.manager = create(DebraManager[MaxThreads])
  result.manager[] = initDebraManager[MaxThreads]()
  result.consumer0Handle = registerThread(result.manager[])
  result.queue = newUnboundedSipmuc[S, T, MaxThreads](result.manager)
  result.consumer0 = result.queue.getConsumer(result.consumer0Handle)

proc cleanup*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads]
) =
  ## Tear down manager. Queue is inline; its `=destroy` is run
  ## automatically when the adapter object goes out of scope.
  ## IMPORTANT: this proc only frees `manager`. Callers must NOT keep
  ## using `a.queue` after `cleanup` because the manager-tracked retired
  ## segments are gone.
  if a.manager != nil:
    reset(a.manager[])
    dealloc(a.manager)
    a.manager = nil

proc push*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads], item: T
): PushResult =
  a.queue.push(item)
  prSuccess

proc pop*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads]
): PopResult[T] =
  let r = a.consumer0.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
