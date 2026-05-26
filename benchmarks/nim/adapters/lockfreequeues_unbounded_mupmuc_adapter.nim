## Adapter for lockfreequeues UnboundedMupmuc-equivalent (unbounded MPMC).
##
## Topology: `mpmc_unbounded`. The unified Queue[T, ccMulti, ccMulti, ST,
## rkEbr, ...] requires a `DebraManager[MT, ccMulti]`; producers AND
## consumers register against the manager on their own thread and obtain
## a `QueueProducer` / `QueueConsumer` view via `queue.getProducer()` /
## `queue.getConsumer()` (the unified API auto-registers the calling
## thread and stores the resulting handle on the view).
##
## This adapter owns the queue + manager + a pre-registered
## producer-0/consumer-0 pair for the 1P/1C smoke shape (registered on
## the init thread). Multi-thread shapes register additional
## producers/consumers per-thread inside the bench harness.
##
## v5.0.0 cascade: the legacy `UnboundedMupmuc[S, T, MT]` type was
## deleted in 3.3.7. The smart-constructor `newUnboundedMupmucQueue` and
## queue-side `getProducer()` / `getConsumer()` replace the legacy
## `newUnboundedMupmuc(...)` + `queue.getProducer(handle)` /
## `queue.getConsumer(handle)` plumbing.

# Fine-grained imports (not the umbrella) to avoid a `PinScopeCardinality`
# ambiguity between the stub (re-exported by the umbrella) and the debra
# enum (brought in by `import debra`). Mirrors the
# lockfreequeues_unbounded_sipmuc_adapter import block.
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
from debra import DebraManager, initDebraManager, DebraRegistrationError
import options
import ../bench_common

const topologiesSupported* = {tMpmcUnbounded}

type
  UnboundedMupmucAdapterQueue[S: static int, T;
                              MaxThreads: static int] =
    Queue[T, ccMulti, ccMulti, stEager, S, MaxThreads]
  UnboundedMupmucAdapterProducer[S: static int, T;
                                 MaxThreads: static int] =
    QueueProducer[T, ccMulti, ccMulti, stEager, S, MaxThreads]
  UnboundedMupmucAdapterConsumer[S: static int, T;
                                 MaxThreads: static int] =
    QueueConsumer[T, ccMulti, ccMulti, stEager, S, MaxThreads]

  LockfreequeuesUnboundedMupmucAdapter*[S: static int, T;
                                        MaxThreads: static int] = object
    ## Heap manager AND heap queue. The manager is heap-pointer because
    ## the unified `newUnboundedMupmucQueue` borrow form takes a
    ## `ptr DebraManager`. The queue is heap-pointer because the cached
    ## `producer0` / `consumer0` views store a `ptr Queue` borrowing
    ## into the queue slot, and an inline queue field would dangle when
    ## the adapter is returned by value from the factory (NRVO is not
    ## guaranteed in Nim). Mirrors the
    ## lockfreequeues_unbounded_mupsic_adapter heap-storage pattern.
    ## ccCons == ccMulti pins manager cardinality to `debra.ccMulti`
    ## per the smart-constructor signature.
    manager*: ptr DebraManager[MaxThreads, debra.ccMulti]
    queue*: ptr UnboundedMupmucAdapterQueue[S, T, MaxThreads]
    producer0*: UnboundedMupmucAdapterProducer[S, T, MaxThreads]
    consumer0*: UnboundedMupmucAdapterConsumer[S, T, MaxThreads]

proc makeLockfreequeuesUnboundedMupmucAdapter*[S: static int, T;
                                                MaxThreads: static int](
    capacity: int = 0   # ignored for unbounded
): LockfreequeuesUnboundedMupmucAdapter[S, T, MaxThreads] =
  result.manager = create(DebraManager[MaxThreads, debra.ccMulti])
  # wasMoved before the deref-assign: `create`'s zero-fill is not tracked by
  # ARC/ORC, so `result.manager[] = ...` would run the DebraManager
  # `=destroy` on uninitialized storage. Mark the slot moved-from first.
  wasMoved(result.manager[])
  result.manager[] = initDebraManager[MaxThreads, debra.ccMulti]()

  result.queue = create(UnboundedMupmucAdapterQueue[S, T, MaxThreads])
  # Same rationale for the queue: the unified Queue carries a typestate
  # `=destroy`, so mark the created slot moved-from before assigning into it.
  wasMoved(result.queue[])
  result.queue[] =
    newUnboundedMupmucQueue[T, stEager, S, MaxThreads](result.manager)
  # Cache producer-0 / consumer-0 for the 1P/1C smoke path, where the
  # init thread IS the operating thread. getProducer/getConsumer no
  # longer register; both views register their debra handles here via
  # attach() on the (init == operating) thread. Multi-thread shapes
  # obtain their own per-thread views via `queue[].getProducer()` /
  # `queue[].getConsumer()` and call `attach()` on their own threads.
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
    result.producer0.attach()
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
    a: var LockfreequeuesUnboundedMupmucAdapter[S, T, MaxThreads]
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
  ##     reset+free the manager.
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
