## Adapter for lockfreequeues' unified `Queue` generic in the bounded
## SPSC cardinality `Queue[T, ccSingle, ccSingle, stEager, rkNone, N,
## 0, 0, 0, 0]`. Mirrors `lockfreequeues_sipsic_adapter.nim` so B3 can
## compute a parity delta between the legacy `Sipsic[N, T]` and the
## new unified Queue under the same harness.
##
## v5.0.0 cascade Track D3.6. Track D3.6.5 will consolidate this with
## the parallel mupsic / sipmuc / mupmuc Queue adapters into a single
## `queue_bounded_adapter.nim` parameterized over `ccProd, ccCons, ST,
## N, P, C`.

import options
import lockfreequeues
import lockfreequeues/queue as q_mod
import ../adapter
from ../bench_common import Topology, tSpsc

const topologiesSupported*: set[Topology] = {tSpsc}

type
  QueueBoundedSipsicAdapter*[N: static int, T] = object
    queue: Queue[T, ccSingle, ccSingle, stEager, rkNone, N, 0, 0, 0, 0]

proc initQueueBoundedSipsicAdapter*[N: static int, T]():
    QueueBoundedSipsicAdapter[N, T] =
  result.queue = q_mod.initQueue[T, ccSingle, ccSingle, stEager, N, 0, 0]()

proc push*[N: static int, T](
    a: var QueueBoundedSipsicAdapter[N, T], item: T
): PushResult =
  if a.queue.push(item): prSuccess else: prFull

proc pop*[N: static int, T](
    a: var QueueBoundedSipsicAdapter[N, T]
): PopResult[T] =
  let item = a.queue.pop()
  if item.isSome:
    PopResult[T](success: true, value: item.get)
  else:
    PopResult[T](success: false)

proc name*[N: static int, T](a: QueueBoundedSipsicAdapter[N, T]): string =
  "lockfreequeues/Queue[ccSingle,ccSingle,rkNone," & $N & "]"
