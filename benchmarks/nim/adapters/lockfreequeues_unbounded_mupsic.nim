## Adapter for lockfreequeues UnboundedMupsic (unbounded MPSC).
##
## UnboundedMupsic differs from the bounded adapters in two ways:
##
## 1. It requires a `DebraManager` for epoch-based segment reclamation.
##    The manager must outlive the queue and be shared across all
##    producer/consumer threads.
##
## 2. Producers register against the manager on their own thread and
##    obtain a `Producer` object via `getProducer`. That object holds a
##    per-thread `ThreadHandle` and CANNOT be created on the main thread
##    and shipped to a worker — handles are per-thread by construction.
##
## Because of (2) we cannot fit UnboundedMupsic into the generic
## `QueueAdapter` concept (which assumes a single `push` callable shared
## across producers). Instead this adapter owns the queue + manager +
## consumer handle and exposes them so that bench code can register
## producers on the worker threads themselves.
##
## The bench harness in `bench_throughput.nim` consumes this adapter
## directly via specialized benchmark procs (mirroring the Mupmuc path).

import lockfreequeues/unbounded_mupsic
import debra

type UnboundedMupsicAdapter*[S: static int, T; MaxThreads: static int] = object
  ## Owns the heap-allocated queue and DebraManager. Consumer's
  ## ThreadHandle is registered at init time on the calling (consumer)
  ## thread. Producer threads must call `registerThread(adapter.manager[])`
  ## themselves and then `queue.getProducer(handle)`.
  queue*: ptr UnboundedMupsic[S, T, MaxThreads]
  manager*: ptr DebraManager[MaxThreads]
  consumerHandle*: ThreadHandle[MaxThreads]

proc initUnboundedMupsicAdapter*[S: static int, T; MaxThreads: static int](
    strategy: DeallocationStrategy = DefaultDeallocationStrategy
): UnboundedMupsicAdapter[S, T, MaxThreads] =
  ## Allocate manager and queue on the heap. Registers the calling thread
  ## as the (single) consumer.
  result.manager = create(DebraManager[MaxThreads])
  result.manager[] = initDebraManager[MaxThreads]()
  result.consumerHandle = registerThread(result.manager[])

  result.queue = create(UnboundedMupsic[S, T, MaxThreads])
  result.queue[] = newUnboundedMupsic[S, T, MaxThreads](
    result.manager, result.consumerHandle, strategy
  )

proc deinitUnboundedMupsicAdapter*[S: static int, T; MaxThreads: static int](
    a: var UnboundedMupsicAdapter[S, T, MaxThreads]
) =
  ## Tear down queue then manager. Order matters: the queue holds
  ## pointers into manager-tracked retired segments, so the queue must
  ## be reset before the manager. `reset` runs `=destroy` on the
  ## referent (so segment memory is freed) without re-invoking it on
  ## the moved-from slot.
  if a.queue != nil:
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil
  if a.manager != nil:
    reset(a.manager[])
    dealloc(a.manager)
    a.manager = nil

proc name*[S: static int, T; MaxThreads: static int](
    a: UnboundedMupsicAdapter[S, T, MaxThreads]
): string =
  "lockfreequeues/UnboundedMupsic[" & $S & "]"
