## Adapter for lockfreequeues UnboundedMpsc-equivalent (unbounded MPSC).
##
## File naming follows the `<library_slug>_adapter.nim` convention.
## `topologiesSupported` is exported here for the bench-driver registry.
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
##    obtain a `QueueProducer` view via `queue.getProducerHere()` (the
##    unified API auto-registers the calling thread). That object holds
##    a per-thread `ThreadHandle` and CANNOT be created on the main
##    thread and shipped to a worker — handles are per-thread by
##    construction.
##
## Because of (2) we cannot fit UnboundedMpsc-equiv into the generic
## `QueueAdapter` concept (which assumes a single `push` callable shared
## across producers). Instead this adapter owns the queue + manager +
## consumer handle and exposes them so that bench code can register
## producers on the worker threads themselves.
##
## The bench harness in `bench_unbounded_mpsc.nim` consumes this
## adapter directly via specialized benchmark procs (was
## `bench_throughput.nim` prior to the PR 2 topology split; then
## `bench_unbounded.nim` until split it per family).
##
## The legacy `UnboundedMpsc[S, T, MT]` type has been removed. The
## borrow-form smart-constructor
## `newUnboundedMpscQueue[T, stEager, S, MaxThreads](addr manager,
## consumerHandle)` replaces the legacy `newUnboundedMpsc(...)` —
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
import lockfreequeues/endpoint
import lockfreequeues/role_tags
from debra import DebraManager, initDebraManager
from ../bench_common import Topology, tMpscUnbounded

const topologiesSupported*: set[Topology] = {tMpscUnbounded}

type
  UnboundedMpscAdapterQueue*[S: static int, T;
                               MaxThreads: static int] =
    Queue[T, ccMulti, ccSingle, stEager, S, MaxThreads]

  UnboundedMpscAdapter*[S: static int, T;
                          MaxThreads: static int] = object
    ## Owns the heap-allocated queue and DebraManager. NO thread is
    ## registered at init time (registration is thread-affine). The
    ## consumer thread registers itself via `adapter.queue[].
    ## attachConsumer()` before its first `pop`; producer threads obtain
    ## a QueueProducer view via `adapter.queue[].getProducerHere()` and call
    ## `.attach()` on their own thread. This keeps the handles bound to
    ## the threads that actually operate, not the constructing thread.
    queue*: ptr UnboundedMpscAdapterQueue[S, T, MaxThreads]
    manager*: ptr DebraManager[MaxThreads, debra.ccSingle]

proc initUnboundedMpscAdapter*[S: static int, T; MaxThreads: static int](
    ): UnboundedMpscAdapter[S, T, MaxThreads] =
  ## Allocate manager and queue on the heap. Does NOT register any
  ## thread: the consumer thread calls `queue.attachConsumer()` and
  ## producer threads call `getProducer().attach()` on their own
  ## threads. The smart-constructor pins ST to stEager at the type
  ## level (matches the legacy 3.2.x default).
  ##
  ## OOM safety: the second `create(...)` can raise `OutOfMemDefect`
  ## after the first allocation succeeded; without a guard the manager
  ## heap block would leak. Mirror the unbounded spmc / mpmc
  ## adapters' destructor-order teardown (reset → dealloc) on the
  ## failure path so the success-path destructor contract still holds.
  result.manager = create(DebraManager[MaxThreads, debra.ccSingle])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.manager[] = ...` would run the DebraManager
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.manager[])

  # Guard manager-value-init + queue `create()` + queue init with a
  # bool-flagged try/finally so an `OutOfMemDefect` (or any other
  # exception) raised by `initDebraManager` or `newUnboundedMpscQueue`
  # tears down the already-allocated manager heap block rather than
  # leaking it. Mirrors the unbounded spmc / mpmc adapters'
  # destructor-order discipline (reset → dealloc) on the failure path.
  # Two-flag guard:
  #  * `managerValueInitOk` — set after `initDebraManager` returns,
  #    indicating the heap manager slot holds a fully-initialized value
  #    (so `reset(manager[])` is safe in the cleanup arm). If false,
  #    the slot is `wasMoved`'d-but-never-assigned and `reset` is
  #    skipped — `dealloc` still runs to free the raw heap block.
  #  * `queueInitOk` — set after `newUnboundedMpscQueue` returns.
  var managerValueInitOk = false
  var queueInitOk = false
  try:
    result.manager[] = initDebraManager[MaxThreads, debra.ccSingle]()
    managerValueInitOk = true
    result.queue = create(UnboundedMpscAdapterQueue[S, T, MaxThreads])
    # Same rationale for the queue: the unified Queue carries a typestate
    # `=destroy`, so mark the created slot moved-from before assigning into it.
    wasMoved(result.queue[])
    result.queue[] =
      newUnboundedMpscQueue[T, stEager, S, MaxThreads](result.manager)
    queueInitOk = true
  finally:
    if not queueInitOk:
      if result.queue != nil:
        # `wasMoved` happened only on success; on partial-init the
        # queue slot's `=destroy` is safe to skip via `dealloc` alone.
        dealloc(result.queue)
        result.queue = nil
      if managerValueInitOk:
        # Manager value is fully initialized; safe to run its `=destroy`.
        # If `initDebraManager` raised before completing, the slot is
        # `wasMoved`'d-but-never-assigned — skip `reset` and just free.
        reset(result.manager[])
      dealloc(result.manager)
      result.manager = nil

proc deinitUnboundedMpscAdapter*[S: static int, T; MaxThreads: static int](
    a: var UnboundedMpscAdapter[S, T, MaxThreads]
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
    a: UnboundedMpscAdapter[S, T, MaxThreads]
): string =
  "lockfreequeues/UnboundedMpsc[" & $S & "]"
