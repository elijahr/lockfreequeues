## Adapter for lockfreequeues Sipsic (bounded SPSC).
##
## Renamed from `lockfreequeues_sipsic.nim` in PR 0 Task 0.9 per design
## section 2.2 (`<library_slug>_adapter.nim`). `topologiesSupported` is
## exported here for PR 3 Task 3.11 consumption.

import options
import lockfreequeues
import ../adapter
from ../bench_common import Topology, tSpsc

const topologiesSupported*: set[Topology] = {tSpsc}

type
  SipsicAdapter*[N: static int, T] = object
    queue: Sipsic[N, T]

proc initSipsicAdapter*[N: static int, T](): SipsicAdapter[N, T] =
  result.queue = initSipsic[N, T]()

proc push*[N: static int, T](a: var SipsicAdapter[N, T], item: T): PushResult =
  if a.queue.push(item): prSuccess else: prFull

proc pop*[N: static int, T](a: var SipsicAdapter[N, T]): PopResult[T] =
  let item = a.queue.pop()
  if item.isSome:
    PopResult[T](success: true, value: item.get)
  else:
    PopResult[T](success: false)

proc name*[N: static int, T](a: SipsicAdapter[N, T]): string =
  "lockfreequeues/Sipsic[" & $N & "]"
