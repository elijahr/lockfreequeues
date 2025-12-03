## Adapter for lockfreequeues Sipsic (bounded SPSC)

import options
import lockfreequeues
import ../adapter

type
  SipsicAdapter*[N: static int, T] = object
    queue: Sipsic[N, T]

proc initSipsicAdapter*[N: static int, T](): SipsicAdapter[N, T] =
  result.queue = initSipsic[N, T]()

proc push*[N: static int, T](a: var SipsicAdapter[N, T], item: T): PushResult =
  if a.queue.push(item):
    prSuccess
  else:
    prFull

proc pop*[N: static int, T](a: var SipsicAdapter[N, T]): PopResult[T] =
  let item = a.queue.pop()
  if item.isSome:
    newPopResult(item.get)
  else:
    emptyPopResult[T]()

proc name*[N: static int, T](a: SipsicAdapter[N, T]): string =
  "lockfreequeues/Sipsic[" & $N & "]"
