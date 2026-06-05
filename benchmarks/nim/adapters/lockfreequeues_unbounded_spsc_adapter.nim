## Adapter for lockfreequeues unbounded SPSC.
##
## the legacy `UnboundedSpsc[S, T]` was absorbed
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
## guaranteed in Nim). Mirrors the lockfreequeues_unbounded_mpsc
## adapter's manager+queue heap-storage pattern; here there is no
## DebraManager because the SPSC branch carries no reclamation
## machinery. `cleanup` resets the cached view first, then resets the
## queue and frees its heap slot.

import options
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags
import ../bench_common

const topologiesSupported* = {tSpscUnbounded}

const SpscMaxThreads = 4
  ## Type-uniform phantom for the spsc-absorbed `Queue` branch — the
  ## branch never touches the debra registry so the value is
  ## immaterial.

type
  UnboundedSpscAdapterQueue[S: static int, T] =
    Queue[T, ccSingle, ccSingle, stEager, S, SpscMaxThreads]
  UnboundedSpscAdapterProducer[S: static int, T] =
    Bound[T, AnyThreadTag, Queue[T, ccSingle, ccSingle, stEager, S, SpscMaxThreads]]

  LockfreequeuesUnboundedSpscAdapter*[S: static int, T] = object
    ## Heap queue (see module doc); the cached `producer0` view borrows
    ## a `ptr Queue` into the heap slot and therefore stays valid for
    ## the lifetime of the adapter regardless of how the adapter value
    ## is moved/copied at the call site.
    queue*: ptr UnboundedSpscAdapterQueue[S, T]
    producer0*: UnboundedSpscAdapterProducer[S, T]
      ## Cached producer view obtained ONCE on the init/operating
      ## thread (mirrors `producer0` in
      ## `lockfreequeues_unbounded_spmc_adapter`). The ccSingle
      ## producer carries no per-thread handle and stores only a
      ## `ptr Queue` into the heap-allocated queue, so it stays valid
      ## for every `push` and avoids recreating the view per call.

proc makeLockfreequeuesUnboundedSpscAdapter*[S: static int, T](
    capacity: int = 0, # ignored for unbounded
): LockfreequeuesUnboundedSpscAdapter[S, T] =
  # OOM safety: `create(...)`, `newUnboundedSpscQueue()`, and
  # `getProducer()` can each raise. The queue value owns segment memory
  # once `newUnboundedSpscQueue` returns, so if a later step raises the
  # queue slot needs `reset(...)` to run its `=destroy` and free those
  # segments; before then, `=destroy` on a moved-from slot is wrong and
  # `dealloc` alone is the right cleanup. Two flags discriminate the
  # cases. Mirrors the mpmc / mpsc / spmc adapter discipline.
  var queueValueInitOk = false
  var queueInitOk = false
  try:
    result.queue = create(UnboundedSpscAdapterQueue[S, T])
    # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
    # ARC/ORC, so `result.queue[] = ...` would run the unified Queue's
    # typestate `=destroy` on uninitialized storage. Mark the slot moved-from
    # first.
    wasMoved(result.queue[])
    result.queue[] = newUnboundedSpscQueue[T, stEager, S, SpscMaxThreads]()
    queueValueInitOk = true
    result.producer0 = result.queue[].getProducerHere()
    queueInitOk = true
  finally:
    if not queueInitOk:
      if result.queue != nil:
        if queueValueInitOk:
          # Queue value is live and owns segment memory; run `=destroy`
          # via `reset` so segments are released before the heap block
          # is freed.
          reset(result.queue[])
        # Slot is now either moved-from (queue value never assigned) or
        # destroyed (reset just ran). `dealloc` releases the raw heap
        # block in both cases.
        dealloc(result.queue)
        result.queue = nil
      # `producer0` is a view borrowing into the (now-freed) queue. On
      # the failure path it was either never assigned (zero state) or
      # holds a ptr into the now-freed slot; reset it to drop the
      # dangling ptr before scope exit. `reset` on zero state is a
      # safe no-op.
      reset(result.producer0)

proc cleanup*[S: static int, T](a: var LockfreequeuesUnboundedSpscAdapter[S, T]) =
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
    a: var LockfreequeuesUnboundedSpscAdapter[S, T], item: T
): PushResult =
  a.producer0.push(item)
  prSuccess

proc pop*[S: static int, T](
    a: var LockfreequeuesUnboundedSpscAdapter[S, T]
): PopResult[T] =
  let r = a.queue[].pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
