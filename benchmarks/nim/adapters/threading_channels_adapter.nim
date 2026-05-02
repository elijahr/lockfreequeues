## Adapter for the nimble ``threading`` package's ``Chan[T]`` type
## (bounded MPMC).
##
## ``threading`` (https://github.com/nim-lang/threading) is the
## post-Nim-2 successor to the experimental ``stew/shims/channels``
## work and the upstream owner of the channel implementation that
## ``std/threading/channels`` ships in newer Nim versions. We import
## it from the nimble registry to get a stable, documented surface;
## the bench adapter consumes ``newChan`` /  ``trySend`` / ``tryRecv``
## with non-blocking semantics so the bench harness's tight push/pop
## loop never blocks a worker thread on a full or empty channel.
##
## Topology: bounded ``mpmc``. ``capacity`` maps to ``newChan[T]``'s
## ``elements`` argument. ``threading.Chan`` is internally an MPMC
## fixed-ring buffer with mutex+condvar synchronization; the bench
## harness uses the non-blocking ``trySend`` / ``tryRecv`` paths so
## the per-call cost is dominated by the lock + memcpy, not the
## condvar wait.
##
## Memory management: ``Chan[T]`` is a reference-counted object that
## owns its underlying buffer. We hold it as a value field on the
## adapter so the destructor runs automatically when the adapter goes
## out of scope; the optional ``deinit`` proc explicitly tears down a
## migrated value before the adapter is dropped.
##
## Build constraint: the ``threading`` package documents that its
## channel implementation requires ``--mm:arc`` / ``--mm:atomicArc`` /
## ``--mm:orc`` and ``--threads:on``. The bench binaries set
## ``--threads:on`` globally and Nim 2.2 defaults to ``--mm:orc``.
##
## Compile-time gating: only included when
## ``-d:adapter_threading_channels_available`` is passed.

when defined(adapter_threading_channels_available):
  import threading/channels
  import ../bench_common
  import ../adapter

  const topologiesSupported* = {tMpmc}

  type ThreadingChannelsAdapter*[T] = object
    chan*: Chan[T]
      ## Reference-counted ``Chan[T]`` from the nimble ``threading``
      ## package. The destructor returned by the package's channel
      ## module reclaims the underlying buffer; we never call it
      ## directly.

  proc makeThreadingChannelsAdapter*[T](capacity: int = 1024
  ): ThreadingChannelsAdapter[T] =
    ## ``capacity`` maps to ``newChan[T]``'s ``elements`` argument.
    ## Defaulted to 1024 for parity with other bounded MPMC adapters.
    ## ``capacity = 0`` would crash ``newChan`` (it requires
    ## ``Positive``); we coerce to ``1`` for safety.
    let cap = if capacity <= 0: 1 else: capacity
    result.chan = newChan[T](elements = cap)

  proc cleanup*[T](a: var ThreadingChannelsAdapter[T]) =
    ## Explicit teardown is a no-op: ``Chan[T]`` cleans itself up
    ## via its move/destroy hooks. The proc exists so callers can
    ## use ``defer: cleanup(a)`` for parity with other adapters'
    ## ``cleanup`` shapes.
    discard a

  proc push*[T](a: var ThreadingChannelsAdapter[T], item: T): PushResult =
    var v = item
    if a.chan.trySend(v):
      prSuccess
    else:
      prFull

  proc pop*[T](a: var ThreadingChannelsAdapter[T]): PopResult[T] =
    var dst: T
    if a.chan.tryRecv(dst):
      PopResult[T](success: true, value: dst)
    else:
      PopResult[T](success: false)

  proc name*[T](a: ThreadingChannelsAdapter[T]): string =
    "threading/Chan[" & $T & "]"
