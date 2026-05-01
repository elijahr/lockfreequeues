## Adapter for Nim built-in channels (bounded MPMC).
##
## Uses the system's Channel[T] type which is automatically available
## when compiling with --threads:on. `topologiesSupported` exported per
## design 2.2 (PR 3 Task 3.11 consumes it).

import ../adapter
from ../bench_common import Topology, tMpmc

const topologiesSupported*: set[Topology] = {tMpmc}

type
  ChannelsAdapter*[T] = object
    chan: ptr Channel[T]

proc initChannelsAdapter*[T](capacity: int): ChannelsAdapter[T] =
  result.chan = create(Channel[T])
  result.chan[].open(capacity)

proc deinitChannelsAdapter*[T](a: var ChannelsAdapter[T]) =
  if a.chan != nil:
    a.chan[].close()
    dealloc(a.chan)
    a.chan = nil

proc push*[T](a: var ChannelsAdapter[T], item: T): PushResult =
  if a.chan[].trySend(item):
    prSuccess
  else:
    prFull

proc pop*[T](a: var ChannelsAdapter[T]): PopResult[T] =
  let res = a.chan[].tryRecv()
  if res.dataAvailable:
    newPopResult(res.msg)
  else:
    emptyPopResult[T]()

proc name*[T](a: ChannelsAdapter[T]): string =
  "nim/channels"
