## Adapter for lockfreequeues Spsc-equivalent (bounded SPSC).
##
## File naming follows the `<library_slug>_adapter.nim` convention.
## `topologiesSupported` is exported here for the bench-driver registry.
##
## The legacy `Spsc[N, T]` type has been removed in favour of the
## unified `Queue[T, ccSingle, ccSingle, stEager, rkNone, N, 0, 0, 0,
## 0]` generic. The adapter surface (`push`, `pop`, `name`, the
## `init*Adapter` factory) is preserved verbatim so bench drivers do
## not need to be re-wired.

import options
import lockfreequeues
import ../adapter
from ../bench_common import Topology, tSpsc

const topologiesSupported*: set[Topology] = {tSpsc}

type SpscAdapter*[N: static int, T] = object
  queue: BQueue[T, ccSingle, ccSingle, N, 0, 0]

proc initSpscAdapter*[N: static int, T](): SpscAdapter[N, T] =
  result.queue = newBQueue[T, ccSingle, ccSingle, N, 0, 0]()

proc push*[N: static int, T](a: var SpscAdapter[N, T], item: T): PushResult =
  if a.queue.push(item): prSuccess else: prFull

proc pop*[N: static int, T](a: var SpscAdapter[N, T]): PopResult[T] =
  let item = a.queue.pop()
  if item.isSome:
    PopResult[T](success: true, value: item.get)
  else:
    PopResult[T](success: false)

proc name*[N: static int, T](a: SpscAdapter[N, T]): string =
  "lockfreequeues/Spsc[" & $N & "]"
