## Adapter for lockfreequeues UnboundedMupsic-equivalent (unbounded MPSC).
##
## Renamed from `lockfreequeues_unbounded_mupsic.nim` in PR 0 Task 0.9
## per design section 2.2. `topologiesSupported` is exported here for
## PR 3 Task 3.11 consumption.
##
## The unified Queue[T, ccMulti, ccSingle, ST, rkEbr, ...] differs from
## the bounded adapters in two ways:
##
## 1. It requires a `DebraManager` for epoch-based segment reclamation.
##    The manager must outlive the queue and be shared across all
##    producer/consumer threads. ccCons == ccSingle on the consumer axis
##    keeps the manager parameterized as `DebraManager[MT, ccSingle]`.
##
## 2. Producers register against the manager on their own thread and
##    obtain a `QueueProducer` view via `queue.getProducer()` (the
##    unified API auto-registers the calling thread). That object holds
##    a per-thread `ThreadHandle` and CANNOT be created on the main
##    thread and shipped to a worker — handles are per-thread by
##    construction.
##
## Because of (2) we cannot fit UnboundedMupsic-equiv into the generic
## `QueueAdapter` concept (which assumes a single `push` callable shared
## across producers). Instead this adapter owns the queue + manager +
## consumer handle and exposes them so that bench code can register
## producers on the worker threads themselves.
##
## The bench harness in `bench_unbounded_mupsic.nim` consumes this
## adapter directly via specialized benchmark procs (was
## `bench_throughput.nim` prior to the PR 2 topology split; then
## `bench_unbounded.nim` until v5.0.0 3.3.9-D split it per family).
##
## v5.0.0 cascade: the legacy `UnboundedMupsic[S, T, MT]` type was
## deleted in 3.3.7. The borrow-form smart-constructor
## `newUnboundedMupsicQueue[T, stEager, S, MaxThreads](addr manager,
## consumerHandle)` replaces the legacy `newUnboundedMupsic(...)` —
## same arguments, same shape, returns the unified Queue value type.

# Fine-grained imports (not the umbrella) so the cardinality enum
# flows from a single module — co-importing `lockfreequeues` and
# `debra` exposes `debra.PinScopeCardinality` AND the stub
# `PinScopeCardinality`, causing ambiguity on the unqualified
# `ccSingle` / `ccMulti` literals used in Queue's static params.
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
from debra import DebraManager, initDebraManager
from ../bench_common import Topology, tMpscUnbounded

const topologiesSupported*: set[Topology] = {tMpscUnbounded}

type
  UnboundedMupsicAdapterQueue*[S: static int, T;
                               MaxThreads: static int] =
    Queue[T, ccMulti, ccSingle, stEager, S, MaxThreads]

  UnboundedMupsicAdapter*[S: static int, T;
                          MaxThreads: static int] = object
    ## Owns the heap-allocated queue and DebraManager. NO thread is
    ## registered at init time (registration is thread-affine). The
    ## consumer thread registers itself via `adapter.queue[].
    ## attachConsumer()` before its first `pop`; producer threads obtain
    ## a QueueProducer view via `adapter.queue[].getProducer()` and call
    ## `.attach()` on their own thread. This keeps the handles bound to
    ## the threads that actually operate, not the constructing thread.
    queue*: ptr UnboundedMupsicAdapterQueue[S, T, MaxThreads]
    manager*: ptr DebraManager[MaxThreads, debra.ccSingle]

proc initUnboundedMupsicAdapter*[S: static int, T; MaxThreads: static int](
    ): UnboundedMupsicAdapter[S, T, MaxThreads] =
  ## Allocate manager and queue on the heap. Does NOT register any
  ## thread: the consumer thread calls `queue.attachConsumer()` and
  ## producer threads call `getProducer().attach()` on their own
  ## threads. The smart-constructor pins ST to stEager at the type
  ## level (matches the legacy 3.2.x default).
  result.manager = create(DebraManager[MaxThreads, debra.ccSingle])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.manager[] = ...` would run the DebraManager
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.manager[])
  result.manager[] = initDebraManager[MaxThreads, debra.ccSingle]()

  result.queue = create(UnboundedMupsicAdapterQueue[S, T, MaxThreads])
  # Same rationale for the queue: the unified Queue carries a typestate
  # `=destroy`, so mark the created slot moved-from before assigning into it.
  wasMoved(result.queue[])
  result.queue[] =
    newUnboundedMupsicQueue[T, stEager, S, MaxThreads](result.manager)

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
