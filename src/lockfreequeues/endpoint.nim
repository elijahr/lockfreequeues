##
## Endpoint types for static thread-affinity. See design §3.3.1.
##
## **Lifecycle vs role — orthogonal layers.** `Endpoint` is the typestate
## for endpoint LIFECYCLE only: `Unbound -> Bound -> Closed`. ROLE is
## carried via the `Tag` generic parameter — one of `SpscProducerTag`,
## `SpscConsumerTag`, `MpmcProducerTag`, `MpmcConsumerTag` (all in
## `role_tags.nim`), or `AnyThreadTag` for the same-thread shortcut path
## explicitly chosen by `getProducerHere` / `getConsumerHere` call sites.
## `Tag` distinctness is enforced at compile time via the
## `{.tags: [TagType, TypestateOp].}` effect pragma on `push`/`pop` procs
## (Task C9) plus `{.forbids: [...].}` regions; the typestate FSM here
## carries no role information.
##
## **Backend specialisation via type-class overloads (M1', C6 spike).**
## The plan template originally gated `handle: ThreadHandle[...]` field
## and `registerThread`/`unregisterThread` calls via
## `when queueT is Queue:`. Nim 2.2's eager generic resolution rejects
## `is Queue` on the 6-static-param `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
## without bound arguments. Per pepper's MCLD call (2026-05-30) + the C6
## 30-min spike: use `concept BQueueType` / `QueueType` type-class match
## on overloaded helper procs. The handle storage lives unconditionally
## on `Bound` and `Closed` (opaque `manager: pointer` + `handleIdx: int`),
## with the Queue overloads casting back to `ThreadHandle[MaxThreads, CC]`
## at the call site where queueT is concrete. The 16-byte cost on
## BQueue endpoints is the M1' tradeoff for keeping the typestate axis
## at 3 generic params and the API uniform.
##
## **Single Endpoint typestate (C4).** The plan template at §C4 sketched
## two parallel typestates `ProducerEndpoint` + `ConsumerEndpoint` with
## identical state sets; typestates 0.12.0 TA-004 forbids sharing state
## types across typestates (see `queue.nim:80-83`). Per pepper's MCLD:
## merge into a single `Endpoint` typestate — role lives in `Tag`,
## lifecycle in `Endpoint`.
##
## **Spike C2.5 result**: single-family import graph clean (outcome G).
##
## **R10 fallback** (per design §3.3.1): if the three-axis generic
## typestate trips a further nim-typestates corner case, drop `queueT`
## from the typestate axis and store it as a non-typestate field.

{.experimental: "strictEffects".}

import ./internal/typestates_dsl
import std/typedthreads

import ./endpoint_types
export endpoint_types
import ./bqueue
import ./queue
import ./role_tags
import ./exceptions
import std/typetraits
import debra/atomics
from debra import
  registerThread, unregisterThread, DebraRegistrationError, DebraManager
from debra/types import ThreadHandle

type
  BQueueType* = concept x
    x is BQueue
    ## Type class matching any `BQueue[...]` instantiation. Used to
    ## dispatch the no-op backend overloads (BQueue endpoints carry no
    ## debra registration).

  QueueType* = concept x
    x is Queue
    ## Type class matching any `Queue[...]` instantiation. Used to
    ## dispatch the debra-integrated backend overloads (Queue endpoints
    ## call `registerThread` / `unregisterThread`).

typestate Endpoint[T, Tag, queueT]:
  consumeOnTransition = false
  strictTransitions = true
  states Unbound[T, Tag, queueT], Bound[T, Tag, queueT], EndpointClosed[T, Tag, queueT]
  transitions:
    Unbound[T, Tag, queueT] -> Bound[T, Tag, queueT]
    Bound[T, Tag, queueT] -> EndpointClosed[T, Tag, queueT]

# ---------------------------------------------------------------------------
# Backend specialisation helpers — dispatched by concept match on queueT.
# ---------------------------------------------------------------------------

proc onBind[T; Tag; queueT: BQueueType](
    b: var Bound[T, Tag, queueT]
) {.gcsafe, raises: [].} =
  ## BQueue endpoints carry no debra registration. No-op.
  discard b

proc onBind[T; Tag; queueT: QueueType](
    b: var Bound[T, Tag, queueT]
) {.gcsafe, raises: [].} =
  ## Queue endpoints register the calling thread with the queue's debra
  ## manager. `queueT` is a concrete `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
  ## at this overload's call site. The SPSC-absorbed Queue branch
  ## (`ccProd == ccSingle and ccCons == ccSingle`) is debra-free per
  ## `queue.nim:280-285`; the `when compiles(b.queue.manager)` feature
  ## test gates the `registerThread` call to the debra-integrated
  ## cardinalities only.
  ##
  ## `DebraRegistrationError` from a saturated registry is converted to
  ## a `Defect` here — typestates 0.12.0 requires `{.transition.}` procs
  ## to have empty `raises:`. The user contract is "do not bind more
  ## threads than the queue's `MaxThreads`"; a saturated registry is
  ## misuse, not a recoverable runtime error.
  when compiles(b.queue.manager):
    try:
      let h = registerThread(b.queue.manager[])
      b.handleManager = cast[pointer](h.manager)
      b.handleIdx = h.idx
    except DebraRegistrationError as e:
      raiseAssert "endpoint.bindToThread: " & e.msg
  else:
    discard b

proc onClose[T; Tag; queueT: BQueueType](
    c: var EndpointClosed[T, Tag, queueT]
) {.gcsafe, raises: [].} =
  ## BQueue endpoints carry no debra registration. No-op.
  discard c

proc onClose[T; Tag; queueT: QueueType](
    c: var EndpointClosed[T, Tag, queueT]
) {.gcsafe, raises: [].} =
  ## Queue endpoints unregister the thread from the queue's debra
  ## manager. The opaque handle storage is cast back to the typed
  ## `ThreadHandle` at this overload's call site. SPSC-absorbed Queue
  ## variants (`queue.nim:280-285`) are debra-free; the
  ## `when compiles(c.queue.manager)` feature test probes the queue's
  ## body split at the concrete instantiation site and short-circuits
  ## for those.
  when compiles(c.queue.manager):
    if c.handleManager == nil:
      return
    type MgrT = typeof(c.queue.manager[])
    let mgr = cast[ptr MgrT](c.handleManager)
    type Handle = ThreadHandle[MgrT.MaxThreads, MgrT.CC]
    let h = Handle(idx: c.handleIdx, manager: mgr)
    unregisterThread(mgr[], h)
  else:
    discard c

# ---------------------------------------------------------------------------
# Lifecycle transitions.
# ---------------------------------------------------------------------------

proc bindToThread*[T; Tag; queueT](
    u: sink Unbound[T, Tag, queueT]
): Bound[T, Tag, queueT] {.transition, tags: [Tag, TypestateOp, RootEffect], gcsafe, raises: [].} =
  ## Bind the endpoint to the calling thread. See design §3.3.2.
  ##
  ## The sugar pragma `{.transition(tag: ...).}` was withdrawn 2026-05-28
  ## (Nim parser rejects `nkObjConstr` pragma form + semantic conflation of
  ## value-typestate with proc-effect). The explicit composed form above is
  ## the only available shape.
  let consumed = move(u)
  result = Bound[T, Tag, queueT](
    queue: consumed.queue, idx: consumed.idx, handleManager: nil, handleIdx: 0
  )
  when defined(debug):
    result.attachedTid = getThreadId()
  onBind[T, Tag, queueT](result)

proc close*[T; Tag; queueT](
    b: sink Bound[T, Tag, queueT]
): EndpointClosed[T, Tag, queueT] {.transition, tags: [Tag, TypestateOp, RootEffect], gcsafe, raises: [].} =
  ## Release the endpoint. Queue endpoints call `unregisterThread`;
  ## BQueue endpoints are a no-op. See design §3.3.2.
  when defined(debug):
    assert getThreadId() == b.attachedTid,
      "close from wrong thread (must match bindToThread thread)"
  let consumed = move(b)
  result = EndpointClosed[T, Tag, queueT](
    queue: consumed.queue,
    handleManager: consumed.handleManager,
    handleIdx: consumed.handleIdx,
  )
  onClose[T, Tag, queueT](result)

# ---------------------------------------------------------------------------
# Endpoint factories (per-flavour). The factory lives in endpoint.nim rather
# than in bqueue.nim / queue.nim to break the import cycle: endpoint.nim
# imports `./bqueue` and `./queue` for the BQueueType/QueueType concepts;
# putting factories the other direction would re-introduce the cycle.
#
# Each factory reserves a per-thread slot on the underlying queue (CAS over
# the queue's producerThreadIds / consumerThreadIds table) and wraps the
# slot index in an `Unbound` endpoint. The caller transitions via
# `bindToThread()` before any `push`/`pop` (lifecycle FSM above).
# ---------------------------------------------------------------------------

proc getProducer*[
    T;
    ccCons: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccMulti, ccCons, N, P, C], idx: int = -1
): Unbound[T, AnyThreadTag, BQueue[T, ccMulti, ccCons, N, P, C]] {.
    raises: [NoProducersAvailableError]
.} =
  ## Reserve a per-thread producer slot on a multi-producer `BQueue` and
  ## return an `Unbound` endpoint owning that slot. The caller transitions
  ## the endpoint to `Bound` via `bindToThread()` before any `push`.
  ##
  ## When `idx >= 0`, the caller pins a specific slot (testing). When
  ## `idx == -1`, the calling thread's `getThreadId()` claims the first
  ## free slot via CAS over `producerThreadIds`.
  result.queue = addr(self)

  if idx >= 0:
    assert idx < P,
      "getProducer(idx) out of range: idx must be < P (producer count)"
    result.idx = idx
    return

  let threadId = getThreadId()

  for i in 0 ..< P:
    if self.producerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  for i in 0 ..< P:
    var expected = 0
    if self.producerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  raise newException(
    NoProducersAvailableError,
    "All producers have been assigned. " &
      "Increase your producer count (P) or setMaxPoolSize(P).",
  )

proc getConsumer*[
    T;
    ccProd: static PinScopeCardinality,
    N, P, C: static int,
](
    self: var BQueue[T, ccProd, ccMulti, N, P, C], idx: int = -1
): Unbound[T, AnyThreadTag, BQueue[T, ccProd, ccMulti, N, P, C]] {.
    raises: [NoConsumersAvailableError]
.} =
  ## Reserve a per-thread consumer slot on a multi-consumer `BQueue` and
  ## return an `Unbound` endpoint. Symmetric to `getProducer`; the caller
  ## must `bindToThread()` before any `pop`.
  result.queue = addr(self)

  if idx >= 0:
    result.idx = idx
    return

  let threadId = getThreadId()

  for i in 0 ..< C:
    if self.consumerThreadIds[i].load(moAcquire) == threadId:
      result.idx = i
      return

  for i in 0 ..< C:
    var expected = 0
    if self.consumerThreadIds[i].compareExchangeWeak(
      expected, threadId, moRelease, moAcquire
    ):
      result.idx = i
      return

  raise newException(NoConsumersAvailableError, "All consumers assigned")

proc getProducer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
): Unbound[T, AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]] {.
    raises: []
.} =
  ## Queue-flavour producer factory. For `ccProd == ccMulti` the
  ## endpoint reserves a producer index against the queue's
  ## `producerCount` atomic; debra registration happens later at
  ## `bindToThread()` via the QueueType overload of `onBind`. For
  ## `ccProd == ccSingle` (SPSC / SPMC) the endpoint carries no
  ## meaningful index (set to `-1`) and `bindToThread()` is a no-op
  ## (debra-free SPSC absorbed body has no manager — gated by
  ## `when compiles(b.queue.manager)`).
  result.queue = addr(self)
  when ccProd == ccMulti:
    let idx = self.producerCount.fetchAdd(1, moAcquire)
    result.idx = idx
  else:
    result.idx = -1

proc getConsumer*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads]
): Unbound[T, AnyThreadTag, Queue[T, ccProd, ccCons, ST, S, MaxThreads]] {.
    raises: []
.} =
  ## Queue-flavour consumer factory. Symmetric to `getProducer`; for
  ## `ccCons == ccMulti` reserves a slot via `consumerCount`; for
  ## `ccCons == ccSingle` the endpoint carries no meaningful index.
  result.queue = addr(self)
  when ccCons == ccMulti:
    let idx = self.consumerCount.fetchAdd(1, moAcquire)
    result.idx = idx
  else:
    result.idx = -1

## ----------------------------------------------------------------------
## R3 mitigation (design §3.3.1, Nim Issue #19013 alias-analysis):
## `Unbound` MUST be a thin `ptr` wrapper over the queue with no
## ref/string/seq/closure subgraph. `system.supportsCopyMem` returns
## `true` iff the type has no GC'd subgraph; static-assert that the
## actual queue families pass.
## ----------------------------------------------------------------------

static:
  doAssert supportsCopyMem(
    Unbound[int, AnyThreadTag, BQueue[int, ccMulti, ccMulti, 64, 4, 4]]
  ),
    "Unbound[..., BQueue[...]] must not contain a ref subgraph; " &
    "see design R3 + Nim Issue #19013"
  doAssert supportsCopyMem(
    Unbound[int, AnyThreadTag, Queue[int, ccMulti, ccSingle, stEager, 16, 4]]
  ),
    "Unbound[..., Queue[...]] must not contain a ref subgraph; " &
    "see design R3 + Nim Issue #19013"

verifyTypestates()
