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
## Implementation note: the underlying `Queue` is held inline (not via
## heap pointer). Inline storage means Nim's automatic `=destroy` runs
## when the adapter goes out of scope, which keeps the adapter free of
## explicit lifecycle plumbing. The `cleanup` proc is retained as a
## no-op for symmetry with the other adapters' cleanup contract.

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
  LockfreequeuesUnboundedSipsicAdapter*[S: static int, T] = object
    queue*: Queue[T, ccSingle, ccSingle, stEager, S, SipsicMaxThreads]

proc makeLockfreequeuesUnboundedSipsicAdapter*[S: static int, T](
    capacity: int = 0   # ignored for unbounded
): LockfreequeuesUnboundedSipsicAdapter[S, T] =
  result.queue =
    newUnboundedSipsicQueue[T, stEager, S, SipsicMaxThreads]()

proc cleanup*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T]
) =
  discard

proc push*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T], item: T
): PushResult =
  var producer = a.queue.getProducer()
  producer.push(item)
  prSuccess

proc pop*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T]
): PopResult[T] =
  let r = a.queue.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
