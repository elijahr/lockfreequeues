## Adapter for lockfreequeues UnboundedMupmuc (unbounded MPMC).
##
## Topology: `mpmc_unbounded`. Requires a `DebraManager`; producers AND
## consumers register against the manager on their own thread and obtain
## a `Producer` / `Consumer` via `queue.getProducer(handle)` /
## `queue.getConsumer(handle)`.
##
## This adapter owns the queue + manager + a pre-registered
## producer-0/consumer-0 pair for the 1P/1C smoke shape. Multi-thread
## shapes register additional producers/consumers per-thread inside the
## bench harness.

import lockfreequeues/unbounded_mupmuc
import debra
import options
import ../bench_common

const topologiesSupported* = {tMpmcUnbounded}

type LockfreequeuesUnboundedMupmucAdapter*[S: static int, T;
                                            MaxThreads: static int] = object
  ## Inline queue (Nim 2.2.6 codegen workaround); heap manager because
  ## UnboundedMupmuc's constructor takes a `ptr DebraManager`.
  manager*: ptr DebraManager[MaxThreads]
  queue*: UnboundedMupmuc[S, T, MaxThreads]
  producer0Handle*: ThreadHandle[MaxThreads]
  consumer0Handle*: ThreadHandle[MaxThreads]
  producer0*: Producer[S, T, MaxThreads]
  consumer0*: Consumer[S, T, MaxThreads]

proc makeLockfreequeuesUnboundedMupmucAdapter*[S: static int, T;
                                                MaxThreads: static int](
    capacity: int = 0   # ignored for unbounded
): LockfreequeuesUnboundedMupmucAdapter[S, T, MaxThreads] =
  result.manager = create(DebraManager[MaxThreads])
  result.manager[] = initDebraManager[MaxThreads]()
  result.producer0Handle = registerThread(result.manager[])
  result.consumer0Handle = registerThread(result.manager[])
  result.queue = newUnboundedMupmuc[S, T, MaxThreads](result.manager)
  result.producer0 = result.queue.getProducer(result.producer0Handle)
  result.consumer0 = result.queue.getConsumer(result.consumer0Handle)

proc cleanup*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedMupmucAdapter[S, T, MaxThreads]
) =
  ## Free manager only; queue is inline and its `=destroy` runs when
  ## the adapter object goes out of scope.
  if a.manager != nil:
    reset(a.manager[])
    dealloc(a.manager)
    a.manager = nil

proc push*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedMupmucAdapter[S, T, MaxThreads], item: T
): PushResult =
  a.producer0.push(item)
  prSuccess

proc pop*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedMupmucAdapter[S, T, MaxThreads]
): PopResult[T] =
  let r = a.consumer0.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
