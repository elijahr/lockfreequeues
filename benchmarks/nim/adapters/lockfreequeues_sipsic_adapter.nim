## Adapter for lockfreequeues Sipsic-equivalent (bounded SPSC).
##
## Renamed from `lockfreequeues_sipsic.nim` in PR 0 Task 0.9 per design
## section 2.2 (`<library_slug>_adapter.nim`). `topologiesSupported` is
## exported here for PR 3 Task 3.11 consumption.
##
## v5.0.0 cascade: the legacy `Sipsic[N, T]` type was deleted in
## 3.3.7 in favour of the unified `Queue[T, ccSingle, ccSingle, stEager,
## rkNone, N, 0, 0, 0, 0]` generic. The adapter surface (`push`, `pop`,
## `name`, the `init*Adapter` factory) is preserved verbatim so bench
## drivers do not need to be re-wired.

import options
import lockfreequeues
import ../adapter
from ../bench_common import Topology, tSpsc

const topologiesSupported*: set[Topology] = {tSpsc}

type
  SipsicAdapter*[N: static int, T] = object
    queue: BQueue[T, ccSingle, ccSingle, N, 0, 0]

proc initSipsicAdapter*[N: static int, T](): SipsicAdapter[N, T] =
  result.queue = newBQueue[T, ccSingle, ccSingle, N, 0, 0]()

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
