## Adapter for Nim's stdlib ``system.Channel`` (bounded blocking
## MPSC).
##
## ``system.Channel`` is a built-in IPC primitive available whenever
## ``--threads:on`` is set; it's a mutex+condvar bounded ring buffer
## with blocking ``send`` / ``recv``. This adapter wraps it as an
## MPSC bounded queue where:
##
## - ``push`` calls ``send``, which **blocks** the producer thread
##   when the channel is full. **Important — apples-to-oranges
##   caveat (design §2.4 footnote):** the lock-free comparison
##   adapters (Boost / MoodyCamel / lockfreequeues) report
##   ``prFull`` and let the harness loop retry; ``system.Channel``
##   instead suspends the producer until the consumer drains a slot.
##   For bench numbers this means the recorded throughput captures
##   the kernel's wakeup latency and is not directly comparable to
##   the lock-free numbers. The bench README's library legend marks
##   this slug with an asterisk.
##
## - ``pop`` calls ``tryRecv``, which is **non-blocking**, so the
##   consumer side matches the other adapters: empty queue returns
##   ``success = false`` and the harness loop retries.
##
## The asymmetric semantics are intentional: a blocking ``recv``
## would never return on the bench's "consume until count met"
## pattern after the producer side has finished, so the consumer
## must poll. The asymmetric harness behaviour also matches how
## ``system.Channel`` is used in real-world Nim code: producers
## ``send`` with back-pressure, consumers spin or use ``peek`` to
## drain.
##
## Topology: ``mpsc`` bounded. The stdlib ``Channel`` is technically
## MPMC-safe internally, but the lockfreequeues bench taxonomy
## reserves the ``mpsc`` slot for blocking-producer adapters and the
## ``mpmc`` slot (existing ``channels_adapter.nim``) for the
## non-blocking ``trySend``-based variant — so a single Nim binary
## can compare the two paths side-by-side without slug collisions.
##
## Compile-time gating: only included when
## ``-d:adapter_nim_channel_available`` is passed.

when defined(adapter_nim_channel_available):
  import ../adapter
  from ../bench_common import Topology, tMpsc

  const topologiesSupported*: set[Topology] = {tMpsc}

  type
    NimChannelAdapter*[T] = object
      chan*: ptr Channel[T]
        ## Heap-allocated so the adapter is movable without
        ## triggering ``Channel``'s implicit copy hooks (which the
        ## stdlib's pre-ARC channel implementation does not
        ## support cleanly).

  proc makeNimChannelAdapter*[T](capacity: int = 1024
  ): NimChannelAdapter[T] =
    ## ``capacity`` is the maximum number of in-flight messages.
    ## ``capacity <= 0`` selects an unlimited channel (matches
    ## stdlib ``open(maxItems = 0)`` semantics) but the bench
    ## binaries always pass an explicit positive value.
    result.chan = create(Channel[T])
    result.chan[].open(if capacity < 0: 0 else: capacity)

  proc cleanup*[T](a: var NimChannelAdapter[T]) =
    if a.chan != nil:
      a.chan[].close()
      dealloc(a.chan)
      a.chan = nil

  proc push*[T](a: var NimChannelAdapter[T], item: T): PushResult =
    ## Blocks until a slot is free. Always returns ``prSuccess`` on
    ## return — see the module-level note for the comparison-
    ## fairness implication.
    if a.chan == nil:
      return prFull
    a.chan[].send(item)
    prSuccess

  proc pop*[T](a: var NimChannelAdapter[T]): PopResult[T] =
    if a.chan == nil:
      return PopResult[T](success: false)
    let res = a.chan[].tryRecv()
    if res.dataAvailable:
      PopResult[T](success: true, value: res.msg)
    else:
      PopResult[T](success: false)

  proc name*[T](a: NimChannelAdapter[T]): string =
    "nim_channel/Channel[" & $T & "]"
