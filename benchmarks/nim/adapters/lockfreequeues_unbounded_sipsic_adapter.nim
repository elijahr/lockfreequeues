## Adapter for lockfreequeues UnboundedSipsic (unbounded SPSC).
##
## Pure SPSC, no per-thread registration: push and pop go through the
## queue object directly. Push always succeeds (the queue grows segments
## on demand) so this adapter's `push` always returns `prSuccess`.
##
## Implementation note: the underlying `UnboundedSipsic[S, T]` is held
## inline (not via heap pointer). Inline storage means Nim's automatic
## `=destroy` runs when the adapter goes out of scope, which keeps the
## adapter free of explicit lifecycle plumbing — and avoids a Nim 2.2.6
## compiler bug ('internal error: getTypeDescAux(tyGenericParam)') that
## triggers when we ask `reset(a.queue[])` or `=destroy(a.queue[])` to
## be specialized at the adapter's instantiation site while bench_common
## is in scope. The `cleanup` proc is retained as a no-op for symmetry
## with the other adapters' cleanup contract.

import options
import lockfreequeues/unbounded_sipsic
import ../bench_common

const topologiesSupported* = {tSpscUnbounded}

type
  LockfreequeuesUnboundedSipsicAdapter*[S: static int, T] = object
    queue*: UnboundedSipsic[S, T]

proc makeLockfreequeuesUnboundedSipsicAdapter*[S: static int, T](
    capacity: int = 0   # ignored for unbounded
): LockfreequeuesUnboundedSipsicAdapter[S, T] =
  result.queue = newUnboundedSipsic[S, T]()

proc cleanup*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T]
) =
  ## No-op: inline storage; Nim's automatic destructor reclaims the
  ## segment chain via UnboundedSipsic's `=destroy` when the adapter
  ## goes out of scope.
  discard

proc push*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T], item: T
): PushResult =
  a.queue.push(item)
  prSuccess

proc pop*[S: static int, T](
    a: var LockfreequeuesUnboundedSipsicAdapter[S, T]
): PopResult[T] =
  let r = a.queue.pop()
  if r.isSome:
    PopResult[T](success: true, value: r.get)
  else:
    PopResult[T](success: false)
