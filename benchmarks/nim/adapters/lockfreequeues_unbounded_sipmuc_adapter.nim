## Adapter for lockfreequeues UnboundedSipmuc-equivalent (unbounded
## SPMC, single producer + N consumers).
##
## Topology: `mpmc_unbounded` with shapes `1p<C>c`. The unified
## Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]
## requires a `DebraManager[MaxThreads, ccMulti]` for epoch-based
## segment reclamation; consumers register against the manager via
## `queue.getConsumer()` ON THEIR OWN THREAD (the unified
## `getConsumer` auto-registers the calling thread and stores the
## resulting `ThreadHandle` on the returned `QueueConsumer` view).
##
## This adapter owns the queue, the manager, and a pre-registered
## consumer-0 view (`getConsumer` called on the init thread) for the
## smoke / 1p1c shape. Multi-consumer shapes (1p2c, 1p4c) register
## additional consumer views per-thread inside the bench harness via
## `adapter.queue[].getConsumer()`.
##
## v5.0.0 cascade: the legacy `UnboundedSipmuc[S, T, MT]` type was
## deleted in 3.3.7. The smart-constructor `newUnboundedSipmucQueue`
## returns the unified Queue value; the legacy
## "consumer0Handle + queue.getConsumer(handle)" plumbing collapses
## into a single `queue.getConsumer()` call on the init thread.

# Fine-grained imports (not the umbrella) so the `ccSingle` /
# `ccMulti` symbols flow from a single enum module. The umbrella
# re-exports `pinscope_stub`'s `PinScopeCardinality`; `import debra`
# re-exports its own (compatible) enum from `debra/cardinality`, and
# co-importing both at user level causes ambiguity on the unqualified
# `ccSingle` / `ccMulti` literals used in Queue's static params.
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
from debra import DebraManager, initDebraManager, DebraRegistrationError
import options
import ../bench_common

const topologiesSupported* = {tMpmcUnbounded}

type
  UnboundedSipmucAdapterQueue[S: static int, T;
                              MaxThreads: static int] =
    Queue[T, ccSingle, ccMulti, stEager, S, MaxThreads]
  UnboundedSipmucAdapterProducer[S: static int, T;
                                 MaxThreads: static int] =
    QueueProducer[T, ccSingle, ccMulti, stEager, S, MaxThreads]
  UnboundedSipmucAdapterConsumer[S: static int, T;
                                 MaxThreads: static int] =
    QueueConsumer[T, ccSingle, ccMulti, stEager, S, MaxThreads]

  LockfreequeuesUnboundedSipmucAdapter*[S: static int, T;
                                        MaxThreads: static int] = object
    ## Manager and queue are BOTH heap-allocated. The manager is
    ## heap-pointer because the unified Queue rkEbr borrow
    ## smart-constructor takes a `ptr DebraManager`. The queue is
    ## heap-pointer because the cached `producer0` / `consumer0` views
    ## store a `ptr Queue` borrowing into the queue slot, and an
    ## inline queue field would dangle when the adapter is returned
    ## by value from the factory (NRVO is not guaranteed in Nim).
    ## Mirrors the lockfreequeues_unbounded_mupsic_adapter heap-storage
    ## pattern.
    ##
    ## ccCons == ccMulti requires a ccMulti-cardinality manager per
    ## nim-debra `cardinality.nim`; the smart-constructor enforces this
    ## at the type level.
    ##
    ## Unified `push` for rkEbr lives on `QueueProducer` (not `Queue`)
    ## across all 4 cardinality combos — including ccSingle producer —
    ## so the adapter caches a `producer0` view for the smoke / 1p1c
    ## shape.
    manager*: ptr DebraManager[MaxThreads, debra.ccMulti]
    queue*: ptr UnboundedSipmucAdapterQueue[S, T, MaxThreads]
    producer0*: UnboundedSipmucAdapterProducer[S, T, MaxThreads]
    consumer0*: UnboundedSipmucAdapterConsumer[S, T, MaxThreads]

proc makeLockfreequeuesUnboundedSipmucAdapter*[S: static int, T;
                                                MaxThreads: static int](
    capacity: int = 0    # ignored for unbounded
): LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads] =
  result.manager = create(DebraManager[MaxThreads, debra.ccMulti])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.manager[] = ...` would run the DebraManager
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.manager[])
  result.manager[] = initDebraManager[MaxThreads, debra.ccMulti]()

  result.queue = create(UnboundedSipmucAdapterQueue[S, T, MaxThreads])
  # Same rationale for the queue: the unified Queue carries a typestate
  # `=destroy`, so mark the created slot moved-from before assigning into it.
  wasMoved(result.queue[])
  result.queue[] =
    newUnboundedSipmucQueue[T, stEager, S, MaxThreads](result.manager)
  # producer0 / consumer0 are the cached views for the smoke / 1p1c
  # round-trip path, where the init thread IS the operating thread.
  # getConsumer/getProducer no longer register; consumer0 registers its
  # debra handle here via attach() on the (init == operating) thread.
  # The single producer (ccSingle) needs no registration. Multi-consumer
  # shapes obtain their own per-thread views via `queue[].getConsumer()`
  # and call `attach()` on their own threads.
  #
  # `attach()` can raise `DebraRegistrationError` if the manager is full
  # (MaxThreads exhausted). If that fires after `create(...)` succeeded,
  # the heap manager AND heap queue would leak because `result` is never
  # fully returned and the deinit (`cleanup`) never runs. Mirror the
  # `cleanup` teardown order — views first, queue, then manager — before
  # re-raising so the failure path matches the success-path destructor
  # contract.
  try:
    result.producer0 = result.queue[].getProducer()
    result.consumer0 = result.queue[].getConsumer()
    result.consumer0.attach()
  except DebraRegistrationError:
    reset(result.producer0)
    reset(result.consumer0)
    reset(result.queue[])
    dealloc(result.queue)
    result.queue = nil
    reset(result.manager[])
    dealloc(result.manager)
    result.manager = nil
    raise

proc cleanup*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads]
) =
  ## Order matters on two axes:
  ##  1. The cached `producer0` / `consumer0` views borrow a pointer into
  ##     the heap-allocated `queue` and carry typestate `=destroy`s.
  ##     They must be reset BEFORE the queue is reset, else their
  ##     scope-exit destructors would touch a destroyed queue
  ##     (use-after-free).
  ##  2. The queue's `=destroy` calls `unbindClient(manager[])`, so the
  ##     manager must outlive the queue. Reset+free the queue first
  ##     (running its destructor while `manager` is still valid), then
  ##     reset+free the manager. After this proc returns the queue is
  ##     destroyed; callers must not keep using `a.queue`.
  if a.queue != nil:
    reset(a.producer0)
    reset(a.consumer0)
    reset(a.queue[])
    dealloc(a.queue)
    a.queue = nil
  if a.manager != nil:
    reset(a.manager[])
    dealloc(a.manager)
    a.manager = nil

proc push*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads], item: T
): PushResult =
  a.producer0.push(item)
  prSuccess

proc pop*[S: static int, T; MaxThreads: static int](
    a: var LockfreequeuesUnboundedSipmucAdapter[S, T, MaxThreads]
): PopResult[T] =
  let r = a.consumer0.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
