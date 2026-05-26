## Adapter for lockfreequeues unbounded SPSC.
##
## Post-3.3.11-B.2.5: the legacy `UnboundedSipsic[S, T]` was absorbed
## into `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]` via
## queue.nim's `when ccProd == ccSingle and ccCons == ccSingle:`
## branch. The branch carries no debra integration — the `MaxThreads`
## param is a type-uniform phantom in that branch.
##
## Pure SPSC, no per-thread registration: push and pop go through the
## queue object directly. Push always succeeds (the queue grows
## segments on demand) so this adapter's `push` always returns
## `prSuccess`.
##
## Implementation note: the underlying `Queue` is held on the heap via
## a `ptr Queue[...]` field. Heap storage is required because the
## cached `producer0` view stores a `ptr Queue` borrowing into the
## queue field, and an inline queue would dangle when the factory's
## return value is copied/moved out of its stack frame (NRVO is not
## guaranteed in Nim). Mirrors the lockfreequeues_unbounded_mupsic
## adapter's manager+queue heap-storage pattern; here there is no
## DebraManager because the SPSC branch carries no reclamation
## machinery. `cleanup` resets the cached view first, then resets the
## queue and frees its heap slot.

import options
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import ../bench_common

const topologiesSupported* = {tSpscUnbounded}

const SipsicMaxThreads = 4
  ## Type-uniform phantom for the sipsic-absorbed `Queue` branch — the
  ## branch never touches the debra registry so the value is
  ## immaterial.

type
  UnboundedSipsicAdapterQueue[S: static int, T] =
    Queue[T, ccSingle, ccSingle, stEager, S, SipsicMaxThreads]
  UnboundedSipsicAdapterProducer[S: static int, T] =
    QueueProducer[T, ccSingle, ccSingle, stEager, S, SipsicMaxThreads]

  LockfreequeuesUnboundedSipsicAdapter*[S: static int, T] = object
    ## Heap queue (see module doc); the cached `producer0` view borrows
    ## a `ptr Queue` into the heap slot and therefore stays valid for
    ## the lifetime of the adapter regardless of how the adapter value
    ## is moved/copied at the call site.
    queue*: ptr UnboundedSipsicAdapterQueue[S, T]
    producer0*: UnboundedSipsicAdapterProducer[S, T]
      ## Cached producer view obtained ONCE on the init/operating
      ## thread (mirrors `producer0` in
      ## `lockfreequeues_unbounded_sipmuc_adapter`). The ccSingle
      ## producer carries no per-thread handle and stores only a
      ## `ptr Queue` into the heap-allocated queue, so it stays valid
      ## for every `push` and avoids recreating the view per call.

proc makeLockfreequeuesUnboundedSipsicAdapter*[S: static int, T](
    capacity: int = 0   # ignored for unbounded
): LockfreequeuesUnboundedSipsicAdapter[S, T] =
  # OOM safety: `create(...)` followed by `newUnboundedSipsicQueue()`
  # can each raise `OutOfMemDefect`. Without a guard the heap slot from
  # a successful `create` would leak if `newUnboundedSipsicQueue` (or
  # any subsequent step) raises. No DebraManager and no attach() in the
  # SPSC branch, so a simple `try/finally` flagged by `queueInitOk` is
  # sufficient. Mirrors the mupsic adapter discipline (skip `reset` on
  # a moved-from but never-initialized slot; `dealloc` alone).
  var queueInitOk = false
  try:
    result.queue = create(UnboundedSipsicAdapterQueue[S, T])
    # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
    # ARC/ORC, so `result.queue[] = ...` would run the unified Queue's
    # typestate `=destroy` on uninitialized storage. Mark the slot moved-from
    # first. Mirrors the lockfreequeues_unbounded_mupsic_adapter pattern.
    wasMoved(result.queue[])
    result.queue[] =
      newUnboundedSipsicQueue[T, stEager, S, SipsicMaxThreads]()
    result.producer0 = result.queue[].getProducer()
    queueInitOk = true
  finally:
    if not queueInitOk:
      if result.queue != nil:
        # `wasMoved` happened only on the success path through the
        # deref-assign; on partial-init the queue slot is either
        # moved-from (init raised) or zero (create raised and the line
        # below never ran). Either way `=destroy` on that state is
        # avoidable — `dealloc` the raw heap block directly.
        dealloc(result.queue)
        result.queue = nil
      # `producer0` is a view borrowing into the (now-freed) queue. On
      # the failure path it was either never assigned (zero state) or
      # holds a ptr into the now-freed slot; reset it to drop the
      # dangling ptr before scope exit. `reset` on zero state is a
      # safe no-op.
      reset(result.producer0)

proc cleanup*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T]
) =
  ## Order matters: the cached `producer0` view borrows a `ptr Queue`
  ## into the heap-allocated queue and carries a typestate `=destroy`.
  ## It must be reset BEFORE the queue is reset, else its scope-exit
  ## destructor would touch a destroyed queue (use-after-free). Then
  ## reset the queue (runs the unified Queue destructor on a valid
  ## referent) and free its heap slot.
  if a.queue != nil:
    reset(a.producer0)
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil

proc push*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T], item: T
): PushResult =
  a.producer0.push(item)
  prSuccess

proc pop*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T]
): PopResult[T] =
  let r = a.queue[].pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
